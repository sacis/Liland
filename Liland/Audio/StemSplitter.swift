import Accelerate

/// Splits stereo music into vocals, bass and drums, and keeps the chosen ones.
///
/// There is no trained model here: each part is recognized by how it looks in a
/// spectrogram. A drum hit is short and spread over many frequencies (a vertical line);
/// vocals and bass hold notes (horizontal lines). Held and hit are told apart by comparing
/// each frequency with the moments around it (median over time) and with the frequencies
/// around it (median over frequency). On top of that, vocals are the held sounds that sit
/// in the center of the stereo image above about 120 Hz, and bass is the held sounds in the
/// center below about 250 Hz. Looking a few moments ahead makes all this much cleaner, at the cost of
/// `latency`.
/// Not thread-safe: feed it from one thread.
final class StemSplitter {
    struct Parts: OptionSet {
        let rawValue: UInt8
        static let vocals = Parts(rawValue: 1 << 0)
        static let bass = Parts(rawValue: 1 << 1)
        static let drums = Parts(rawValue: 1 << 2)
    }

    private static let size = 2048
    private static let hop = 512
    private static let bins = size / 2
    /// Moments looked at after the one being split: about 85 ms at 48 kHz.
    private static let lookAhead = 8
    /// Moments for the held part, centered on the one being split.
    private static let timeSpan = 2 * lookAhead + 1
    /// Neighboring frequencies for the hits.
    private static let frequencySpan = 17
    /// How decisively each bit of sound goes to one side: higher leaks less but sounds less natural.
    private static let sharpness: Float = 4
    /// How strictly vocals and bass must sit in the center: higher drops more of the instruments beside them.
    private static let vocalCenterFocus: Float = 16
    private static let bassCenterFocus: Float = 6

    /// How far the output lags behind the input: a whole frame, plus the look-ahead.
    static let latency = size + lookAhead * hop
    /// Where new input samples are written; the frame is processed once they reach the end.
    private static let fill = size - hop

    private let forward = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD)
    private let inverse = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .INVERSE)
    /// Square root of a Hann window, applied before and after, so the overlapping frames add back to the input.
    private let window: UnsafeMutableBufferPointer<Float>
    /// How much of each frequency can be vocals (none of the bass range) or bass (only the bass range).
    private let vocalRange: UnsafeMutableBufferPointer<Float>
    private let bassRange: UnsafeMutableBufferPointer<Float>
    /// Where a kick drum lives. Its thump is too narrow to stand out from the frequencies
    /// around it, so there a hit is whatever jumps above the moments around it.
    private let kickRange: UnsafeMutableBufferPointer<Float>

    private struct Channel {
        /// The last `size` input samples; new ones are written from `fill` on.
        let input: UnsafeMutableBufferPointer<Float>
        /// Overlapping frames being summed.
        let accumulator: UnsafeMutableBufferPointer<Float>
        /// Finished samples, read out while the next hop comes in.
        let output: UnsafeMutableBufferPointer<Float>
        /// The spectra of the last `lookAhead + 1` frames, waiting for the frames after them.
        let real: UnsafeMutableBufferPointer<Float>
        let imaginary: UnsafeMutableBufferPointer<Float>
        /// The frame being split, masked.
        let maskedReal: UnsafeMutableBufferPointer<Float>
        let maskedImaginary: UnsafeMutableBufferPointer<Float>
    }

    private let channels: [Channel]
    private var position = StemSplitter.fill
    private var frameCount = 0

    private let frame: UnsafeMutableBufferPointer<Float>
    private let evenSamples: UnsafeMutableBufferPointer<Float>
    private let oddSamples: UnsafeMutableBufferPointer<Float>
    /// The magnitudes of the last `timeSpan` frames, one row each.
    private let history: UnsafeMutableBufferPointer<Float>
    private let sortScratch: UnsafeMutableBufferPointer<Float>

    init(sampleRate: Double) {
        window = .allocate(capacity: Self.size)
        for index in 0..<Self.size {
            window[index] = sqrt(0.5 - 0.5 * cos(2 * .pi * Float(index) / Float(Self.size)))
        }
        vocalRange = .allocate(capacity: Self.bins)
        bassRange = .allocate(capacity: Self.bins)
        kickRange = .allocate(capacity: Self.bins)
        let binWidth = Float(sampleRate) / Float(Self.size)
        for bin in 0..<Self.bins {
            let frequency = Float(bin) * binWidth
            vocalRange[bin] = Self.fade(frequency, from: 120, to: 250)
            bassRange[bin] = 1 - Self.fade(frequency, from: 160, to: 300)
            kickRange[bin] = 1 - Self.fade(frequency, from: 150, to: 250)
        }

        let spectra = (Self.lookAhead + 1) * Self.bins
        channels = (0..<2).map { _ in
            Channel(
                input: .allocate(capacity: Self.size),
                accumulator: .allocate(capacity: Self.size),
                output: .allocate(capacity: Self.hop),
                real: .allocate(capacity: spectra),
                imaginary: .allocate(capacity: spectra),
                maskedReal: .allocate(capacity: Self.bins),
                maskedImaginary: .allocate(capacity: Self.bins)
            )
        }
        frame = .allocate(capacity: Self.size)
        evenSamples = .allocate(capacity: Self.bins)
        oddSamples = .allocate(capacity: Self.bins)
        history = .allocate(capacity: Self.bins * Self.timeSpan)
        sortScratch = .allocate(capacity: max(Self.timeSpan, Self.frequencySpan))
        reset()
    }

    deinit {
        if let forward { vDSP_DFT_DestroySetup(forward) }
        if let inverse { vDSP_DFT_DestroySetup(inverse) }
        for channel in channels {
            [channel.input, channel.accumulator, channel.output, channel.real, channel.imaginary,
             channel.maskedReal, channel.maskedImaginary].forEach { $0.deallocate() }
        }
        [window, vocalRange, bassRange, kickRange, frame, evenSamples, oddSamples, history, sortScratch].forEach { $0.deallocate() }
    }

    /// Forgets the music heard so far, to start over without echoes of it.
    func reset() {
        for channel in channels {
            channel.input.update(repeating: 0)
            channel.accumulator.update(repeating: 0)
            channel.output.update(repeating: 0)
            channel.real.update(repeating: 0)
            channel.imaginary.update(repeating: 0)
        }
        history.update(repeating: 0)
        frameCount = 0
        position = Self.fill
    }

    /// Replaces the samples of both channels, in place, with the parts to keep.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, keeping parts: Parts) {
        let first = channels[0], second = channels[1]
        for index in 0..<frames {
            first.input[position] = left[index]
            second.input[position] = right[index]
            left[index] = first.output[position - Self.fill]
            right[index] = second.output[position - Self.fill]
            position += 1
            if position == Self.size {
                position = Self.fill
                processFrame(keeping: parts)
            }
        }
    }

    private func processFrame(keeping parts: Parts) {
        guard let forward, let inverse else { return }
        let slots = Self.lookAhead + 1
        // The newest frame is analyzed; the one `lookAhead` frames older is split and played.
        let newest = (frameCount % slots) * Self.bins
        let splitting = ((frameCount + 1) % slots) * Self.bins
        let newestRow = (frameCount % Self.timeSpan) * Self.bins
        let splittingRow = ((frameCount + Self.timeSpan - Self.lookAhead) % Self.timeSpan) * Self.bins
        frameCount += 1

        for channel in channels {
            vDSP_vmul(channel.input.baseAddress!, 1, window.baseAddress!, 1, frame.baseAddress!, 1, vDSP_Length(Self.size))
            transform(forward, from: frame, toReal: channel.real.baseAddress! + newest, imaginary: channel.imaginary.baseAddress! + newest)
        }

        let left = channels[0], right = channels[1]
        for bin in 0..<Self.bins {
            let index = newest + bin
            let power = left.real[index] * left.real[index] + right.real[index] * right.real[index]
                + (bin == 0 ? 0 : left.imaginary[index] * left.imaginary[index] + right.imaginary[index] * right.imaginary[index])
            history[newestRow + bin] = power.squareRoot()
        }

        let sharpness = Self.sharpness
        for bin in 0..<Self.bins {
            let heldMagnitude = heldMagnitude(at: bin)
            let jump = max(0, history[splittingRow + bin] - heldMagnitude) * kickRange[bin]
            let held = pow(heldMagnitude, sharpness)
            let hit = pow(max(hitMagnitude(at: bin, row: splittingRow), jump), sharpness)
            let total = held + hit
            var mask: Float = 0
            if total > 1e-20 {
                let isHeld = held / total
                if parts.contains(.drums) { mask += hit / total }
                if !parts.isDisjoint(with: [.vocals, .bass]) {
                    let center = centerShare(at: splitting + bin, isFirstBin: bin == 0)
                    if parts.contains(.bass) { mask += bassRange[bin] * pow(center, Self.bassCenterFocus) * isHeld }
                    if parts.contains(.vocals) { mask += vocalRange[bin] * pow(center, Self.vocalCenterFocus) * isHeld }
                }
                mask = min(mask, 1)
            }
            for channel in channels {
                channel.maskedReal[bin] = channel.real[splitting + bin] * mask
                channel.maskedImaginary[bin] = channel.imaginary[splitting + bin] * mask
            }
        }

        // The DFT pair scales by 2 × size, and the overlapping windows add up to 2.
        var scale = 1 / Float(Self.size * 4)
        let count = vDSP_Length(Self.size)
        for channel in channels {
            inverseTransform(inverse, real: channel.maskedReal, imaginary: channel.maskedImaginary, to: frame)
            vDSP_vmul(frame.baseAddress!, 1, window.baseAddress!, 1, frame.baseAddress!, 1, count)
            vDSP_vsma(frame.baseAddress!, 1, &scale, channel.accumulator.baseAddress!, 1, channel.accumulator.baseAddress!, 1, count)

            channel.output.baseAddress!.update(from: channel.accumulator.baseAddress!, count: Self.hop)
            channel.accumulator.baseAddress!.update(from: channel.accumulator.baseAddress! + Self.hop, count: Self.size - Self.hop)
            (channel.accumulator.baseAddress! + Self.size - Self.hop).update(repeating: 0, count: Self.hop)
            channel.input.baseAddress!.update(from: channel.input.baseAddress! + Self.hop, count: Self.size - Self.hop)
        }
    }

    /// 1 when both channels carry the same sound at this frequency, 0 when it's all on one side
    /// (or the sides are out of phase).
    private func centerShare(at index: Int, isFirstBin: Bool) -> Float {
        let left = channels[0], right = channels[1]
        let leftImaginary = isFirstBin ? 0 : left.imaginary[index]
        let rightImaginary = isFirstBin ? 0 : right.imaginary[index]
        let shared = 2 * (left.real[index] * right.real[index] + leftImaginary * rightImaginary)
        let total = left.real[index] * left.real[index] + leftImaginary * leftImaginary
            + right.real[index] * right.real[index] + rightImaginary * rightImaginary
        guard total > 1e-20, shared > 0 else { return 0 }
        return shared / total
    }

    /// The median of this frequency over the frames around the one being split.
    private func heldMagnitude(at bin: Int) -> Float {
        for row in 0..<Self.timeSpan {
            sortScratch[row] = history[row * Self.bins + bin]
        }
        return median(count: Self.timeSpan)
    }

    /// The median of the frequencies around this one, in the frame being split.
    private func hitMagnitude(at bin: Int, row: Int) -> Float {
        let half = Self.frequencySpan / 2
        let low = max(0, bin - half)
        let high = min(Self.bins - 1, bin + half)
        for neighbor in low...high {
            sortScratch[neighbor - low] = history[row + neighbor]
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

    /// 0 below `low`, 1 above `high`, and a smooth curve in between.
    private static func fade(_ frequency: Float, from low: Float, to high: Float) -> Float {
        guard frequency > low else { return 0 }
        guard frequency < high else { return 1 }
        return 0.5 - 0.5 * cos(.pi * (frequency - low) / (high - low))
    }

    // MARK: - Transforms

    /// The real-input DFT wants even samples in one array and odd samples in the other.
    private func transform(
        _ setup: vDSP_DFT_Setup,
        from samples: UnsafeMutableBufferPointer<Float>,
        toReal real: UnsafeMutablePointer<Float>,
        imaginary: UnsafeMutablePointer<Float>
    ) {
        samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.bins) { pairs in
            var split = DSPSplitComplex(realp: evenSamples.baseAddress!, imagp: oddSamples.baseAddress!)
            vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(Self.bins))
        }
        vDSP_DFT_Execute(setup, evenSamples.baseAddress!, oddSamples.baseAddress!, real, imaginary)
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
