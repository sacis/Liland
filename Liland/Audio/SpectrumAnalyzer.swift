import Accelerate

/// Splits audio into four bands, from bass to treble, and scales each to 0...1.
/// Each band follows its own recent peak, so the bars move the same at any volume.
///
/// To keep the bars close to the music, it looks at the last 1024 samples (enough to tell
/// bass from treble) but re-analyzes every 256 new samples, about every 5 ms.
/// Not thread-safe: feed it from one queue.
final class SpectrumAnalyzer {
    static let bandCount = 4

    private static let size = 1024
    private static let hop = 256
    private static let bands: [(low: Float, high: Float)] = [(40, 150), (150, 600), (600, 2_500), (2_500, 9_000)]
    /// Decibels between an empty and a full bar.
    private static let range: Float = 30
    /// Below this the music is treated as silence instead of being amplified.
    private static let silence: Float = -75
    /// How fast a band's peak falls back after a loud moment.
    private static let peakDecayPerSecond: Float = 3
    /// Time constants of the bars: they jump up with each beat and fall a little slower.
    private static let riseTime: Float = 0.015
    private static let fallTime: Float = 0.09

    private let dft = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(SpectrumAnalyzer.size), .FORWARD)
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: SpectrumAnalyzer.size, isHalfWindow: false)

    /// The last `size` samples, written in a circle starting at `writeIndex`.
    private var history = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    private var writeIndex = 0
    private var newSamples = 0

    private var frame = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    private var inReal = [Float](repeating: 0, count: SpectrumAnalyzer.size / 2)
    private var inImag = [Float](repeating: 0, count: SpectrumAnalyzer.size / 2)
    private var outReal = [Float](repeating: 0, count: SpectrumAnalyzer.size / 2)
    private var outImag = [Float](repeating: 0, count: SpectrumAnalyzer.size / 2)
    private var power = [Float](repeating: 0, count: SpectrumAnalyzer.size / 2)

    private var peaks = [Float](repeating: -40, count: SpectrumAnalyzer.bandCount)
    private var smoothed = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)

    deinit {
        if let dft { vDSP_DFT_DestroySetup(dft) }
    }

    /// Takes interleaved samples (the first channel is used) and returns the newest levels,
    /// or nil when fewer than `hop` new samples have arrived since the last analysis.
    func process(_ samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double) -> [Double]? {
        var analyzed = false
        for index in stride(from: 0, to: samples.count, by: channels) {
            history[writeIndex] = samples[index]
            writeIndex = (writeIndex + 1) % Self.size
            newSamples += 1
            if newSamples >= Self.hop {
                newSamples = 0
                analyze(sampleRate: Float(sampleRate))
                analyzed = true
            }
        }
        return analyzed ? smoothed.map(Double.init) : nil
    }

    private func analyze(sampleRate: Float) {
        // Oldest sample first: the part after writeIndex, then the part before it.
        let tail = Self.size - writeIndex
        frame.withUnsafeMutableBufferPointer { frame in
            history.withUnsafeBufferPointer { history in
                frame.baseAddress!.update(from: history.baseAddress! + writeIndex, count: tail)
                (frame.baseAddress! + tail).update(from: history.baseAddress!, count: writeIndex)
            }
        }
        vDSP.multiply(frame, window, result: &frame)
        computePower()

        let binWidth = sampleRate / Float(Self.size)
        let seconds = Float(Self.hop) / sampleRate
        let rise = 1 - exp(-seconds / Self.riseTime)
        let fall = 1 - exp(-seconds / Self.fallTime)

        for (band, edges) in Self.bands.enumerated() {
            let low = max(1, Int(edges.low / binWidth))
            let high = min(power.count - 1, max(low, Int(edges.high / binWidth)))
            let energy = vDSP.mean(power[low...high])
            let decibels = 10 * log10(energy + 1e-12)

            peaks[band] = max(decibels, peaks[band] - Self.peakDecayPerSecond * seconds, Self.silence + Self.range)
            let level = decibels < Self.silence ? 0 : min(max((decibels - (peaks[band] - Self.range)) / Self.range, 0), 1)
            smoothed[band] += (level - smoothed[band]) * (level > smoothed[band] ? rise : fall)
        }
    }

    /// Power of each frequency bin, scaled so a full-scale sine wave reads about 0 dB.
    private func computePower() {
        let half = Self.size / 2
        // The real-input DFT wants even samples in one array and odd samples in the other.
        frame.withUnsafeBufferPointer { frame in
            frame.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { pairs in
                inReal.withUnsafeMutableBufferPointer { real in
                    inImag.withUnsafeMutableBufferPointer { imag in
                        var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imag.baseAddress!)
                        vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(half))
                    }
                }
            }
        }
        guard let dft else { return }
        vDSP_DFT_Execute(dft, inReal, inImag, &outReal, &outImag)

        let scale = 16 / Float(Self.size * Self.size)
        for bin in 0..<half {
            power[bin] = (outReal[bin] * outReal[bin] + outImag[bin] * outImag[bin]) * scale
        }
    }
}
