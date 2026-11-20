import Foundation

/// Not thread-safe: feed it from one queue.
final class SpectrumAnalyzer {
    static let bandCount = 6

    private static let bands: [(low: Float, high: Float)] = [
        (40, 100), (100, 200), (200, 560), (560, 1_700), (1_700, 5_000), (5_000, 12_000),
    ]
    private static let averagingTimes: [Float] = [0.045, 0.03, 0.015, 0.015, 0.015, 0.015]
    private static let hop = 256
    private static let fallPerSecond: Float = 60
    private static let silence: Float = -80

    private static let memorySeconds: Float = 3
    private static let memoryStep: Float = 0.05
    private static let memoryLength = Int((memorySeconds / memoryStep).rounded())
    private static let quietPercentile: Float = 0.1
    private static let loudPercentile: Float = 0.9
    private static let minimumSpan: Float = 12
    private static let maximumSpan: Float = 40
    private static let springResponse: Float = 0.065

    private static let attackWeights: [Float] = [0.8, 0.8, 0.3, 0.3, 0, 0]
    private static let attackAveraging: Float = 0.15
    private static let attackRange: Float = 8
    private static let attackFallPerSecond: Float = 3

    private static let filtersPerBand = 4
    private var filters: [Biquad] = []
    private var powers = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var averagings = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var sampleRate: Double = 0
    private var newSamples = 0
    private var mixPower: Float = 0
    private var mixAveraging: Float = 0

    private var held = [Float](repeating: -.infinity, count: SpectrumAnalyzer.bandCount)
    private var memory = [[Float]](repeating: [], count: SpectrumAnalyzer.bandCount)
    private var memoryIndex = 0
    private var sinceMemory: Float = .infinity
    private var quiet = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var loud = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var scratch: [Float] = []

    private var recent = [Float](repeating: .nan, count: SpectrumAnalyzer.bandCount)
    private var attack = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)

    private var smoothed = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var velocity = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)

    func process(_ samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double) -> [Double]? {
        if sampleRate != self.sampleRate { setUp(sampleRate: sampleRate) }
        let channels = max(channels, 1)
        let scale = 1 / Float(channels)
        var analyzed = false

        var frame = 0
        while frame + channels <= samples.count {
            let count = min(Self.hop - newSamples, (samples.count - frame) / channels)
            filters.withUnsafeMutableBufferPointer { filters in
                powers.withUnsafeMutableBufferPointer { powers in
                    averagings.withUnsafeBufferPointer { averagings in
                        for _ in 0..<count {
                            var sample: Float = 0
                            for channel in 0..<channels { sample += samples[frame + channel] }
                            sample *= scale
                            frame += channels

                            mixPower += (sample * sample - mixPower) * mixAveraging
                            for band in 0..<Self.bandCount {
                                var y = sample
                                let first = band * Self.filtersPerBand
                                for filter in first..<first + Self.filtersPerBand { y = filters[filter].process(y) }
                                powers[band] += (y * y - powers[band]) * averagings[band]
                            }
                        }
                    }
                }
            }
            newSamples += count
            if newSamples >= Self.hop {
                newSamples = 0
                update(seconds: Float(Self.hop) / Float(sampleRate))
                analyzed = true
            }
        }
        return analyzed ? smoothed.map { Double(min(max($0, 0), 1)) } : nil
    }

    private func setUp(sampleRate: Double) {
        self.sampleRate = sampleRate
        func averaging(_ time: Float) -> Float { 1 - exp(-1 / (time * Float(sampleRate))) }
        filters = Self.bands.flatMap { edges -> [Biquad] in
            [
                .highPass(edges.low, sampleRate: sampleRate), .highPass(edges.low, sampleRate: sampleRate),
                .lowPass(edges.high, sampleRate: sampleRate), .lowPass(edges.high, sampleRate: sampleRate),
            ]
        }
        averagings = Self.averagingTimes.map(averaging)
        mixAveraging = averaging(0.05)
    }

    private func update(seconds: Float) {
        let isSilent = Self.decibels(mixPower) < Self.silence

        let averagingStep = 1 - exp(-seconds / Self.attackAveraging)
        for band in powers.indices {
            let now = Self.decibels(powers[band])
            if recent[band].isNaN { recent[band] = now }
            let jump = min(max((now - recent[band]) / Self.attackRange, 0), 1)
            recent[band] += (now - recent[band]) * averagingStep
            attack[band] = isSilent ? 0 : max(jump, attack[band] - Self.attackFallPerSecond * seconds)
        }

        let levels = powers.indices.map { band in
            held[band] = max(Self.decibels(powers[band]), held[band] - Self.fallPerSecond * seconds)
            return held[band]
        }

        sinceMemory += seconds
        if !isSilent && sinceMemory >= Self.memoryStep {
            sinceMemory = 0
            remember(levels)
        }

        let omega = 2 * Float.pi / Self.springResponse
        let decay = exp(-omega * seconds)
        for (band, decibels) in levels.enumerated() {
            let span = min(max(loud[band] - quiet[band], Self.minimumSpan), Self.maximumSpan)
            let empty = loud[band] - span
            let plain = isSilent || memory[band].isEmpty ? 0 : min(max((decibels - empty) / span, 0), 1)
            let weight = Self.attackWeights[band]
            moveSpring(band, toward: weight * attack[band] + (1 - weight) * plain, omega: omega, decay: decay, seconds: seconds)
        }
    }

    private func remember(_ levels: [Float]) {
        for (band, decibels) in levels.enumerated() {
            if memory[band].count < Self.memoryLength {
                memory[band].append(decibels)
            } else {
                memory[band][memoryIndex] = decibels
            }
            scratch = memory[band]
            scratch.sort()
            let last = Float(scratch.count - 1)
            quiet[band] = scratch[Int((last * Self.quietPercentile).rounded())]
            loud[band] = scratch[Int((last * Self.loudPercentile).rounded())]
        }
        memoryIndex = (memoryIndex + 1) % Self.memoryLength
    }

    private func moveSpring(_ band: Int, toward target: Float, omega: Float, decay: Float, seconds: Float) {
        let offset = smoothed[band] - target
        let push = velocity[band] + omega * offset
        let newOffset = (offset + push * seconds) * decay
        velocity[band] = (velocity[band] - omega * push * seconds) * decay
        smoothed[band] = target + newOffset
    }

    private static func decibels(_ power: Float) -> Float {
        10 * log10(power + 1e-12)
    }
}
