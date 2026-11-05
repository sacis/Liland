import Accelerate

/// Real-time split by spectrogram shape (held vs. hit, via median filters) and stereo center; no model.
/// Not thread-safe: feed it from one thread.
final class StemSplitter {
    struct Parts: OptionSet {
        let rawValue: UInt8
        static let vocals = Parts(rawValue: 1 << 0)
        static let bass = Parts(rawValue: 1 << 1)
        static let drums = Parts(rawValue: 1 << 2)
        /// Only `DemucsSplitter` keeps it; this splitter can't tell it from the rest.
        static let guitar = Parts(rawValue: 1 << 3)
    }

    private static let size = 2048
    private static let hop = 512
    private static let bins = size / 2
    private static let lookAhead = 8 // frames, ~85 ms at 48 kHz
    private static let timeSpan = 2 * lookAhead + 1
    private static let frequencySpan = 17
    private static let bassSharpness: Float = 4
    private static let hitSharpness: Float = 4
    /// Higher drops side instruments; kept loose for vocals so reverb and backing vocals don't go robotic.
    private static let vocalCenterFocus: Float = 2
    /// A singer's "s" is dead center; cymbals heard by the overhead mics are spread out.
    private static let consonantCenterFocus: Float = 32
    private static let bassCenterFocus: Float = 6
    /// Smooths the vocal mask's robotic-sounding flicker; bass and drums are better off without it.
    private static let vocalMemory: Float = 0.7
    /// A kick's thump is gone within ~100 ms, a bass note lasts: keep what still sounds `lookAhead` later.
    private static let bassSustainFocus: Float = 2
    /// ~0.75 s: spans a few kicks, yet catches the bass coming back after a break.
    private static let presenceSpan = 70
    private static let presenceMinimum = 24
    /// dB. Without a steady bass line that owns the lows, only leftovers remain, so it fades out.
    private static let continuityRange: (low: Float, high: Float) = (-18, -13)
    private static let shareRange: (low: Float, high: Float) = (-28, -22)
    private static let presenceOpening: Float = 0.15 // s
    private static let presenceClosing: Float = 1 // s

    private static let slots = lookAhead + 2

    static let latency = size + lookAhead * hop // samples
    private static let fill = size - hop

    private let forward = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD)
    private let inverse = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .INVERSE)
    /// Square-root Hann, applied before and after, so the overlapping frames add back to the input.
    private let window: UnsafeMutableBufferPointer<Float>
    private let vocalRange: UnsafeMutableBufferPointer<Float>
    private let bassRange: UnsafeMutableBufferPointer<Float>
    /// A kick's thump is too narrow to stand out across frequencies, so there a hit is a jump over time.
    private let kickRange: UnsafeMutableBufferPointer<Float>
    private let consonantRange: UnsafeMutableBufferPointer<Float>

    private struct Channel {
        let input: UnsafeMutableBufferPointer<Float>
        let accumulator: UnsafeMutableBufferPointer<Float>
        let output: UnsafeMutableBufferPointer<Float>
        let real: UnsafeMutableBufferPointer<Float>
        let imaginary: UnsafeMutableBufferPointer<Float>
        let maskedReal: UnsafeMutableBufferPointer<Float>
        let maskedImaginary: UnsafeMutableBufferPointer<Float>
    }

    private let channels: [Channel]
    private var position = StemSplitter.fill
    private var frameCount = 0

    /// Mono bass kept apart so the exciter never touches anything else.
    private let bassMasks: UnsafeMutableBufferPointer<Float>
    private let bassReal: UnsafeMutableBufferPointer<Float>
    private let bassImaginary: UnsafeMutableBufferPointer<Float>
    private let bassAccumulator: UnsafeMutableBufferPointer<Float>
    private let bassOutput: UnsafeMutableBufferPointer<Float>
    private let sampleRate: Double
    private var exciter: BassExciter
    private var isExciting = false
    private var isKeepingBass = false

    private var bassPresence: Float = 0
    private let presenceHistory: UnsafeMutableBufferPointer<Float>
    private let presenceScratch: UnsafeMutableBufferPointer<Float>
    private var presenceCount = 0
    private var bassEnergy: Float = 0
    private var lowEnergy: Float = 0

    private let frame: UnsafeMutableBufferPointer<Float>
    private let evenSamples: UnsafeMutableBufferPointer<Float>
    private let oddSamples: UnsafeMutableBufferPointer<Float>
    private let history: UnsafeMutableBufferPointer<Float>
    private let sortScratch: UnsafeMutableBufferPointer<Float>
    private let centers: UnsafeMutableBufferPointer<Float>
    private let vocalMasks: UnsafeMutableBufferPointer<Float>
    private let otherMasks: UnsafeMutableBufferPointer<Float>

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        exciter = BassExciter(sampleRate: sampleRate)
        window = .allocate(capacity: Self.size)
        for index in 0..<Self.size {
            window[index] = sqrt(0.5 - 0.5 * cos(2 * .pi * Float(index) / Float(Self.size)))
        }
        vocalRange = .allocate(capacity: Self.bins)
        bassRange = .allocate(capacity: Self.bins)
        kickRange = .allocate(capacity: Self.bins)
        consonantRange = .allocate(capacity: Self.bins)
        let binWidth = Float(sampleRate) / Float(Self.size)
        for bin in 0..<Self.bins {
            let frequency = Float(bin) * binWidth
            vocalRange[bin] = Self.fade(frequency, from: 120, to: 250)
            bassRange[bin] = 1 - Self.fade(frequency, from: 160, to: 300)
            kickRange[bin] = 1 - Self.fade(frequency, from: 150, to: 250)
            consonantRange[bin] = Self.fade(frequency, from: 1_500, to: 2_500) * (1 - Self.fade(frequency, from: 11_000, to: 14_000))
        }

        let spectra = Self.slots * Self.bins
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
        centers = .allocate(capacity: Self.bins)
        vocalMasks = .allocate(capacity: Self.bins)
        otherMasks = .allocate(capacity: Self.bins)
        bassMasks = .allocate(capacity: Self.bins)
        bassReal = .allocate(capacity: Self.bins)
        bassImaginary = .allocate(capacity: Self.bins)
        bassAccumulator = .allocate(capacity: Self.size)
        bassOutput = .allocate(capacity: Self.hop)
        presenceHistory = .allocate(capacity: Self.presenceSpan)
        presenceScratch = .allocate(capacity: Self.presenceSpan)
        reset()
    }

    deinit {
        if let forward { vDSP_DFT_DestroySetup(forward) }
        if let inverse { vDSP_DFT_DestroySetup(inverse) }
        for channel in channels {
            [channel.input, channel.accumulator, channel.output, channel.real, channel.imaginary,
             channel.maskedReal, channel.maskedImaginary].forEach { $0.deallocate() }
        }
        [window, vocalRange, bassRange, kickRange, consonantRange, frame, evenSamples, oddSamples, history, sortScratch,
         centers, vocalMasks, otherMasks, bassMasks, bassReal, bassImaginary, bassAccumulator, bassOutput,
         presenceHistory, presenceScratch]
            .forEach { $0.deallocate() }
    }

    func reset() {
        for channel in channels {
            channel.input.update(repeating: 0)
            channel.accumulator.update(repeating: 0)
            channel.output.update(repeating: 0)
            channel.real.update(repeating: 0)
            channel.imaginary.update(repeating: 0)
        }
        history.update(repeating: 0)
        vocalMasks.update(repeating: 0)
        bassAccumulator.update(repeating: 0)
        bassOutput.update(repeating: 0)
        frameCount = 0
        position = Self.fill
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, keeping parts: Parts) {
        let first = channels[0], second = channels[1]
        // Harmonics would land on a kept voice and sound buzzy, and the voice fills that range anyway.
        let excites = parts.contains(.bass) && !parts.contains(.vocals)
        if excites && !isExciting {
            exciter = BassExciter(sampleRate: sampleRate)
            bassAccumulator.update(repeating: 0)
            bassOutput.update(repeating: 0)
        }
        isExciting = excites
        if parts.contains(.bass) && !isKeepingBass {
            bassPresence = 0
            presenceCount = 0
            bassEnergy = 0
            lowEnergy = 0
        }
        isKeepingBass = parts.contains(.bass)
        for index in 0..<frames {
            first.input[position] = left[index]
            second.input[position] = right[index]
            let harmonics = excites ? exciter.process(bassOutput[position - Self.fill]) : 0
            left[index] = first.output[position - Self.fill] + harmonics
            right[index] = second.output[position - Self.fill] + harmonics
            position += 1
            if position == Self.size {
                position = Self.fill
                processFrame(keeping: parts)
            }
        }
    }

    private func processFrame(keeping parts: Parts) {
        guard let forward, let inverse else { return }
        let slots = Self.slots
        // The newest frame is analyzed; the one `lookAhead` frames older is split and played.
        let newest = (frameCount % slots) * Self.bins
        let splitting = ((frameCount + slots - Self.lookAhead) % slots) * Self.bins
        let before = ((frameCount + slots - Self.lookAhead - 1) % slots) * Self.bins
        let after = ((frameCount + slots - Self.lookAhead + 1) % slots) * Self.bins
        let newestRow = (frameCount % Self.timeSpan) * Self.bins
        let splittingRow = ((frameCount + Self.timeSpan - Self.lookAhead) % Self.timeSpan) * Self.bins
        frameCount += 1

        for channel in channels {
            vDSP_vmul(channel.input.baseAddress!, 1, window.baseAddress!, 1, frame.baseAddress!, 1, vDSP_Length(Self.size))
            transform(forward, from: frame, toReal: channel.real.baseAddress! + newest, imaginary: channel.imaginary.baseAddress! + newest)
        }

        for bin in 0..<Self.bins {
            history[newestRow + bin] = power(at: newest, bin).squareRoot()
        }
        if !parts.isEmpty {
            measureCenters(before: before, splitting: splitting, after: after)
        }

        var foundBass: Float = 0, low: Float = 0
        for bin in 0..<Self.bins {
            let heldMagnitude = heldMagnitude(at: bin)
            let jump = max(0, history[splittingRow + bin] - heldMagnitude) * kickRange[bin]
            let hitMagnitude = max(hitMagnitude(at: bin, row: splittingRow), jump)
            var vocals: Float = 0, other: Float = 0, bass: Float = 0
            if heldMagnitude + hitMagnitude > 1e-10 {
                let isHit = Self.share(of: hitMagnitude, against: heldMagnitude, sharpness: Self.hitSharpness)
                let consonant = consonantRange[bin] * pow(centers[bin], Self.consonantCenterFocus)
                if parts.contains(.drums) {
                    other += isHit * (1 - consonant)
                }
                if parts.contains(.bass) {
                    let isHeld = Self.share(of: heldMagnitude, against: hitMagnitude, sharpness: Self.bassSharpness)
                    // The note may have slid a little by then, so look at the frequencies beside it too.
                    var later: Float = 0
                    for neighbor in max(bin - 1, 0)...min(bin + 1, Self.bins - 1) {
                        later = max(later, history[newestRow + neighbor])
                    }
                    let now = history[splittingRow + bin]
                    let lasts = now > 1e-10 ? min(1, later / now) : 1
                    bass = bassRange[bin] * pow(centers[bin], Self.bassCenterFocus) * isHeld * pow(lasts, Self.bassSustainFocus)

                    let power = power(at: splitting, bin)
                    foundBass += bass * bass * power
                    low += bassRange[bin] * power
                    bass *= bassPresence
                    other += bass
                }
                if parts.contains(.vocals) {
            // Centered non-hits (keeps syllable onsets with the voice), plus centered consonants.
                    vocals = vocalRange[bin] * pow(centers[bin], Self.vocalCenterFocus) * (1 - isHit) + isHit * consonant
                }
            }
            vocalMasks[bin] = Self.vocalMemory * vocalMasks[bin] + (1 - Self.vocalMemory) * vocals
            otherMasks[bin] = other
            bassMasks[bin] = bass
        }
        if parts.contains(.bass) {
            updateBassPresence(found: foundBass, low: low)
        }

        for bin in 0..<Self.bins {
            let mask = min(vocalMasks[bin] + otherMasks[bin], 1)
            for channel in channels {
                channel.maskedReal[bin] = channel.real[splitting + bin] * mask
                channel.maskedImaginary[bin] = channel.imaginary[splitting + bin] * mask
            }
        }
        for channel in channels {
            overlapAdd(inverse, real: channel.maskedReal, imaginary: channel.maskedImaginary, into: channel.accumulator, finishing: channel.output)
            channel.input.baseAddress!.update(from: channel.input.baseAddress! + Self.hop, count: Self.size - Self.hop)
        }

        if isExciting {
            let left = channels[0], right = channels[1]
            for bin in 0..<Self.bins {
                bassReal[bin] = (left.real[splitting + bin] + right.real[splitting + bin]) / 2 * bassMasks[bin]
                bassImaginary[bin] = (left.imaginary[splitting + bin] + right.imaginary[splitting + bin]) / 2 * bassMasks[bin]
            }
            overlapAdd(inverse, real: bassReal, imaginary: bassImaginary, into: bassAccumulator, finishing: bassOutput)
        }
    }

    private func updateBassPresence(found: Float, low: Float) {
        let moment = Float(Self.hop) / Float(sampleRate)
        let smoothing = 1 - exp(-1 / Float(Self.presenceSpan))
        bassEnergy += (found - bassEnergy) * smoothing
        lowEnergy += (low - lowEnergy) * smoothing
        presenceHistory[presenceCount % Self.presenceSpan] = found
        presenceCount += 1

        let count = min(presenceCount, Self.presenceSpan)
        guard count >= Self.presenceMinimum else { return }
        presenceScratch.baseAddress!.update(from: presenceHistory.baseAddress!, count: count)
        let peak = presenceScratch[0..<count].max() ?? 0
        let typical = Self.median(presenceScratch, count: count)
        guard peak > 1e-20, lowEnergy > 1e-20 else {
            bassPresence = 0
            return
        }
        let continuity = 10 * log10(max(typical / peak, 1e-12))
        let share = 10 * log10(max(bassEnergy / lowEnergy, 1e-12))
        let target = Self.fade(continuity, from: Self.continuityRange.low, to: Self.continuityRange.high)
            * Self.fade(share, from: Self.shareRange.low, to: Self.shareRange.high)
        let time = target > bassPresence ? Self.presenceOpening : Self.presenceClosing
        bassPresence += (target - bassPresence) * (1 - exp(-moment / time))
    }

    private func overlapAdd(
        _ inverse: vDSP_DFT_Setup,
        real: UnsafeMutableBufferPointer<Float>,
        imaginary: UnsafeMutableBufferPointer<Float>,
        into accumulator: UnsafeMutableBufferPointer<Float>,
        finishing output: UnsafeMutableBufferPointer<Float>
    ) {
        // The DFT pair scales by 2 × size, and the overlapping windows add up to 2.
        var scale = 1 / Float(Self.size * 4)
        let count = vDSP_Length(Self.size)
        inverseTransform(inverse, real: real, imaginary: imaginary, to: frame)
        vDSP_vmul(frame.baseAddress!, 1, window.baseAddress!, 1, frame.baseAddress!, 1, count)
        vDSP_vsma(frame.baseAddress!, 1, &scale, accumulator.baseAddress!, 1, accumulator.baseAddress!, 1, count)

        output.baseAddress!.update(from: accumulator.baseAddress!, count: Self.hop)
        accumulator.baseAddress!.update(from: accumulator.baseAddress! + Self.hop, count: Self.size - Self.hop)
        (accumulator.baseAddress! + Self.size - Self.hop).update(repeating: 0, count: Self.hop)
    }

    private func power(at slot: Int, _ bin: Int) -> Float {
        let left = channels[0], right = channels[1]
        let index = slot + bin
        let real = left.real[index] * left.real[index] + right.real[index] * right.real[index]
        // The first bin packs the lowest and the highest frequency, both without phase.
        guard bin > 0 else { return real }
        return real + left.imaginary[index] * left.imaginary[index] + right.imaginary[index] * right.imaginary[index]
    }

    /// 1 when both channels match, 0 when one-sided or out of phase; averaged over neighbors.
    private func measureCenters(before: Int, splitting: Int, after: Int) {
        let left = channels[0], right = channels[1]
        for bin in 0..<Self.bins {
            var shared: Float = 0, total: Float = 0
            func add(_ slot: Int) {
                for neighbor in max(bin - 1, 0)...min(bin + 1, Self.bins - 1) {
                    let index = slot + neighbor
                    shared += 2 * left.real[index] * right.real[index]
                    total += left.real[index] * left.real[index] + right.real[index] * right.real[index]
                    if neighbor > 0 {
                        shared += 2 * left.imaginary[index] * right.imaginary[index]
                        total += left.imaginary[index] * left.imaginary[index] + right.imaginary[index] * right.imaginary[index]
                    }
                }
            }
            add(before)
            add(splitting)
            add(after)
            centers[bin] = total > 1e-20 ? max(0, shared / total) : 0
        }
    }

    private func heldMagnitude(at bin: Int) -> Float {
        for row in 0..<Self.timeSpan {
            sortScratch[row] = history[row * Self.bins + bin]
        }
        return Self.median(sortScratch, count: Self.timeSpan)
    }

    private func hitMagnitude(at bin: Int, row: Int) -> Float {
        let half = Self.frequencySpan / 2
        let low = max(0, bin - half)
        let high = min(Self.bins - 1, bin + half)
        for neighbor in low...high {
            sortScratch[neighbor - low] = history[row + neighbor]
        }
        return Self.median(sortScratch, count: high - low + 1)
    }

    private static func median(_ values: UnsafeMutableBufferPointer<Float>, count: Int) -> Float {
        for index in 1..<count {
            let value = values[index]
            var slot = index
            while slot > 0 && values[slot - 1] > value {
                values[slot] = values[slot - 1]
                slot -= 1
            }
            values[slot] = value
        }
        return values[count / 2]
    }

    private static func share(of part: Float, against other: Float, sharpness: Float) -> Float {
        let part = pow(part, sharpness), total = part + pow(other, sharpness)
        return total > 0 ? part / total : 0
    }

    private static func fade(_ value: Float, from low: Float, to high: Float) -> Float {
        guard value > low else { return 0 }
        guard value < high else { return 1 }
        return 0.5 - 0.5 * cos(.pi * (value - low) / (high - low))
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
