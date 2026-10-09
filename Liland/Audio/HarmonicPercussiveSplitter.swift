import Accelerate

/// Splits stereo music into what holds a note (voices, bass, instruments) and what hits
/// (drums), and keeps one of them.
///
/// In a spectrogram a held note is a horizontal line and a drum hit a vertical one, so
/// each frequency is compared with its recent past (median over time, the held part) and
/// with its neighbors in the same moment (median over frequency, the hits). Only past
/// moments are used, so it works live at the cost of `latency` samples.
/// Not thread-safe: feed it from one thread.
final class HarmonicPercussiveSplitter {
    enum Part { case harmonic, percussive }

    private static let size = 2048
    private static let hop = 512
    private static let bins = size / 2
    /// Moments for the held part: about 0.2 s at 44.1/48 kHz.
    private static let timeSpan = 17
    /// Neighboring frequencies for the hits.
    private static let frequencySpan = 17

    /// How far the output lags behind the input: a whole frame.
    static let latency = size
    /// Where new input samples are written; the frame is processed once they reach the end.
    private static let fill = size - hop

    private let forward = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD)
    private let inverse = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .INVERSE)
    /// Square root of a Hann window, applied before and after, so the overlapping frames add back to the input.
    private let window: UnsafeMutableBufferPointer<Float>

    private struct Channel {
        /// The last `size` input samples; new ones are written from `fill` on.
        let input: UnsafeMutableBufferPointer<Float>
        /// Overlapping frames being summed.
        let accumulator: UnsafeMutableBufferPointer<Float>
        /// Finished samples, read out while the next hop comes in.
        let output: UnsafeMutableBufferPointer<Float>
        let real: UnsafeMutableBufferPointer<Float>
        let imaginary: UnsafeMutableBufferPointer<Float>
    }

    private let channels: [Channel]
    private var position = HarmonicPercussiveSplitter.fill

    private let frame: UnsafeMutableBufferPointer<Float>
    private let evenSamples: UnsafeMutableBufferPointer<Float>
    private let oddSamples: UnsafeMutableBufferPointer<Float>
    private let magnitude: UnsafeMutableBufferPointer<Float>
    /// The last `timeSpan` magnitudes, one row each.
    private let history: UnsafeMutableBufferPointer<Float>
    private var historyRow = 0
    private let sortScratch: UnsafeMutableBufferPointer<Float>

    init() {
        window = .allocate(capacity: Self.size)
        for index in 0..<Self.size {
            window[index] = sqrt(0.5 - 0.5 * cos(2 * .pi * Float(index) / Float(Self.size)))
        }
        channels = (0..<2).map { _ in
            Channel(
                input: .allocate(capacity: Self.size),
                accumulator: .allocate(capacity: Self.size),
                output: .allocate(capacity: Self.hop),
                real: .allocate(capacity: Self.bins),
                imaginary: .allocate(capacity: Self.bins)
            )
        }
        frame = .allocate(capacity: Self.size)
        evenSamples = .allocate(capacity: Self.bins)
        oddSamples = .allocate(capacity: Self.bins)
        magnitude = .allocate(capacity: Self.bins)
        history = .allocate(capacity: Self.bins * Self.timeSpan)
        sortScratch = .allocate(capacity: max(Self.timeSpan, Self.frequencySpan))
        reset()
    }

    deinit {
        if let forward { vDSP_DFT_DestroySetup(forward) }
        if let inverse { vDSP_DFT_DestroySetup(inverse) }
        for channel in channels {
            [channel.input, channel.accumulator, channel.output, channel.real, channel.imaginary].forEach { $0.deallocate() }
        }
        [window, frame, evenSamples, oddSamples, magnitude, history, sortScratch].forEach { $0.deallocate() }
    }

    /// Forgets the music heard so far, to start over without echoes of it.
    func reset() {
        for channel in channels {
            channel.input.update(repeating: 0)
            channel.accumulator.update(repeating: 0)
            channel.output.update(repeating: 0)
        }
        history.update(repeating: 0)
        historyRow = 0
        position = Self.fill
    }

    /// Replaces the samples of both channels, in place, with the part to keep.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, keeping part: Part) {
        let first = channels[0], second = channels[1]
        for index in 0..<frames {
            first.input[position] = left[index]
            second.input[position] = right[index]
            left[index] = first.output[position - Self.fill]
            right[index] = second.output[position - Self.fill]
            position += 1
            if position == Self.size {
                position = Self.fill
                processFrame(keeping: part)
            }
        }
    }

    private func processFrame(keeping part: Part) {
        guard let forward, let inverse else { return }

        for channel in channels {
            vDSP_vmul(channel.input.baseAddress!, 1, window.baseAddress!, 1, frame.baseAddress!, 1, vDSP_Length(Self.size))
            transform(forward, from: frame, toReal: channel.real, imaginary: channel.imaginary)
        }

        // Both channels share one mask, measured on their sum, so the stereo image stays put.
        let left = channels[0], right = channels[1]
        for bin in 0..<Self.bins {
            if bin == 0 {
                // The first bin packs the lowest and the highest frequency, both without phase.
                magnitude[bin] = abs(left.real[0] + right.real[0])
            } else {
                magnitude[bin] = hypot(left.real[bin] + right.real[bin], left.imaginary[bin] + right.imaginary[bin])
            }
        }
        history.baseAddress!.advanced(by: historyRow * Self.bins).update(from: magnitude.baseAddress!, count: Self.bins)
        historyRow = (historyRow + 1) % Self.timeSpan

        for bin in 0..<Self.bins {
            let held = heldMagnitude(at: bin)
            let hit = hitMagnitude(at: bin)
            let heldPower = held * held, hitPower = hit * hit
            let total = heldPower + hitPower
            let mask = total > 1e-12 ? (part == .harmonic ? heldPower : hitPower) / total : 0
            for channel in channels {
                channel.real[bin] *= mask
                channel.imaginary[bin] *= mask
            }
        }

        // The DFT pair scales by 2 × size, and the overlapping windows add up to 2.
        var scale = 1 / Float(Self.size * 4)
        let count = vDSP_Length(Self.size)
        for channel in channels {
            inverseTransform(inverse, real: channel.real, imaginary: channel.imaginary, to: frame)
            vDSP_vmul(frame.baseAddress!, 1, window.baseAddress!, 1, frame.baseAddress!, 1, count)
            vDSP_vsma(frame.baseAddress!, 1, &scale, channel.accumulator.baseAddress!, 1, channel.accumulator.baseAddress!, 1, count)

            channel.output.baseAddress!.update(from: channel.accumulator.baseAddress!, count: Self.hop)
            channel.accumulator.baseAddress!.update(from: channel.accumulator.baseAddress! + Self.hop, count: Self.size - Self.hop)
            (channel.accumulator.baseAddress! + Self.size - Self.hop).update(repeating: 0, count: Self.hop)
            channel.input.baseAddress!.update(from: channel.input.baseAddress! + Self.hop, count: Self.size - Self.hop)
        }
    }

    private func heldMagnitude(at bin: Int) -> Float {
        for row in 0..<Self.timeSpan {
            sortScratch[row] = history[row * Self.bins + bin]
        }
        return median(count: Self.timeSpan)
    }

    private func hitMagnitude(at bin: Int) -> Float {
        let half = Self.frequencySpan / 2
        let low = max(0, bin - half)
        let high = min(Self.bins - 1, bin + half)
        for neighbor in low...high {
            sortScratch[neighbor - low] = magnitude[neighbor]
        }
        return median(count: high - low + 1)
    }

    /// Median of the first `count` values of `sortScratch`, which it reorders.
    private func median(count: Int) -> Float {
        for index in 1..<count {
            let value = sortScratch[index]
            var slot = index
            while slot > 0 && sortScratch[slot - 1] > value {
                sortScratch[slot] = sortScratch[slot - 1]
                slot -= 1
            }
            sortScratch[slot] = value
        }
        return sortScratch[count / 2]
    }

    // MARK: - Transforms

    /// The real-input DFT wants even samples in one array and odd samples in the other.
    private func transform(
        _ setup: vDSP_DFT_Setup,
        from samples: UnsafeMutableBufferPointer<Float>,
        toReal real: UnsafeMutableBufferPointer<Float>,
        imaginary: UnsafeMutableBufferPointer<Float>
    ) {
        samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.bins) { pairs in
            var split = DSPSplitComplex(realp: evenSamples.baseAddress!, imagp: oddSamples.baseAddress!)
            vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(Self.bins))
        }
        vDSP_DFT_Execute(setup, evenSamples.baseAddress!, oddSamples.baseAddress!, real.baseAddress!, imaginary.baseAddress!)
    }

    private func inverseTransform(
        _ setup: vDSP_DFT_Setup,
        real: UnsafeMutableBufferPointer<Float>,
        imaginary: UnsafeMutableBufferPointer<Float>,
        to samples: UnsafeMutableBufferPointer<Float>
    ) {
        vDSP_DFT_Execute(setup, real.baseAddress!, imaginary.baseAddress!, evenSamples.baseAddress!, oddSamples.baseAddress!)
        samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.bins) { pairs in
            var split = DSPSplitComplex(realp: evenSamples.baseAddress!, imagp: oddSamples.baseAddress!)
            vDSP_ztoc(&split, 1, pairs, 2, vDSP_Length(Self.bins))
        }
    }
}
