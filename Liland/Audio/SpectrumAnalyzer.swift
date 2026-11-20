import Foundation

/// Splits audio into six bands, from sub-bass to treble, and scales each to 0...1, so
/// each bar shows when its part of the music hits: the kick, the bass, the guitar, the
/// cymbals.
///
/// Works like the spectrum meters of audio hardware: every band has its own band-pass
/// filter and level detector, run on every sample. A Fourier transform would have to wait
/// for a window of sound (90 ms to tell bass apart) and showed each hit about 100 ms late,
/// off the beat; the filters answer within a few milliseconds.
///
/// The bands follow the ones measured from a screen recording of the iPhone player (left
/// to right: kick, bass, low mids, mids, presence, treble), with the bass bands moved to
/// cover the kick's punch at 60–100 Hz. Unlike the iPhone, each band is scaled between its
/// own loud and quiet moments of the last few seconds, not against the whole mix, so a
/// quiet band moves as much as a loud one.
///
/// The low bands mostly show attacks (how much the sound just jumped) rather than level:
/// a held bass note would otherwise keep their bars high and wobbling, hiding the kick.
/// Not thread-safe: feed it from one queue.
final class SpectrumAnalyzer {
    static let bandCount = 6

    private static let bands: [(low: Float, high: Float)] = [
        (40, 100), (100, 200), (200, 560), (560, 1_700), (1_700, 5_000), (5_000, 12_000),
    ]
    /// How long each band's energy is averaged, to smooth out the sound wave's own ripple
    /// (slower in the bass, where the wave itself is slower) without blurring the hits.
    private static let averagingTimes: [Float] = [0.045, 0.03, 0.015, 0.015, 0.015, 0.015]
    /// Levels are taken every this many samples, about every 5 ms.
    private static let hop = 256
    /// After a hit, a bar falls this fast, in decibels per second, and ignores any smaller
    /// wobble on the way down: it only turns back up for the next hit. That's what keeps it
    /// calm between beats.
    private static let fallPerSecond: Float = 60
    /// Below this the music is treated as silence instead of being amplified.
    private static let silence: Float = -80

    /// Each band remembers its level over the last few seconds (one reading every 50 ms):
    /// long enough to know the song's range, short enough to follow it into a softer or
    /// louder part.
    private static let memorySeconds: Float = 3
    private static let memoryStep: Float = 0.05
    private static let memoryLength = Int((memorySeconds / memoryStep).rounded())
    /// A dot and a full bar sit at these points of what the band remembers. Not the very
    /// quietest and loudest: one stray dip or spike would squash every other moment.
    private static let quietPercentile: Float = 0.1
    private static let loudPercentile: Float = 0.9
    /// Decibels between a dot and a full bar stay within these. The lower limit keeps a
    /// steady band (a held note) from turning tiny wobbles into big jumps; the upper one
    /// keeps a band that drops out (no bass for a moment) from flattening the rest.
    private static let minimumSpan: Float = 12
    private static let maximumSpan: Float = 40
    /// A light spring between levels, so the bars glide instead of stepping.
    private static let springResponse: Float = 0.065

    /// How much of each bar is attack rather than level: most of it in the bass, some in
    /// the low mids, none in the treble, whose level already pulses with every cymbal.
    private static let attackWeights: [Float] = [0.8, 0.8, 0.3, 0.3, 0, 0]
    /// An attack is measured against the band's average over about this long…
    private static let attackAveraging: Float = 0.15
    /// …and a jump this many decibels above it fills the bar.
    private static let attackRange: Float = 8
    /// After an attack, its part of the bar empties in a third of a second.
    private static let attackFallPerSecond: Float = 3

    /// Every band's four filters in a row, then each band's averaged energy and how fast
    /// it averages. Flat arrays: this runs for every sample, six bands at a time.
    private static let filtersPerBand = 4
    private var filters: [Biquad] = []
    private var powers = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var averagings = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var sampleRate: Double = 0
    private var newSamples = 0
    private var mixPower: Float = 0
    private var mixAveraging: Float = 0

    /// Each band's level after a hit, falling at `fallPerSecond` until the next one.
    private var held = [Float](repeating: -.infinity, count: SpectrumAnalyzer.bandCount)
    /// Each band's recent levels in decibels, a circle written at `memoryIndex`.
    private var memory = [[Float]](repeating: [], count: SpectrumAnalyzer.bandCount)
    private var memoryIndex = 0
    private var sinceMemory: Float = .infinity
    /// Each band's quiet and loud levels, from `memory`.
    private var quiet = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var loud = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var scratch: [Float] = []

    /// Each band's recent average level in decibels, and its latest attack (0...1).
    private var recent = [Float](repeating: .nan, count: SpectrumAnalyzer.bandCount)
    private var attack = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)

    private var smoothed = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var velocity = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)

    /// Takes interleaved samples (the channels are mixed) and returns the newest levels,
    /// or nil when fewer than `hop` new samples have arrived since the last levels.
    func process(_ samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double) -> [Double]? {
        if sampleRate != self.sampleRate { setUp(sampleRate: sampleRate) }
        let channels = max(channels, 1)
        let scale = 1 / Float(channels)
        var analyzed = false

        var frame = 0
        while frame + channels <= samples.count {
            // Filter up to the next hop in one go, then take the levels.
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
        // The spring may overshoot a hair past empty or full; the bar stops there instead.
        return analyzed ? smoothed.map { Double(min(max($0, 0), 1)) } : nil
    }

    private func setUp(sampleRate: Double) {
        self.sampleRate = sampleRate
        func averaging(_ time: Float) -> Float { 1 - exp(-1 / (time * Float(sampleRate))) }
        // Two high-passes and two low-passes: each edge falls 24 dB per octave.
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
            // Up at once with a hit, then a steady fall.
            held[band] = max(Self.decibels(powers[band]), held[band] - Self.fallPerSecond * seconds)
            return held[band]
        }

        // Silence (a pause, the gap between songs) isn't part of the song's range.
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

    /// The exact step of a critically damped spring, stable at any step size.
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
