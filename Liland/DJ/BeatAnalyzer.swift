import Accelerate
import os

/// Listens to one deck as it arrives and finds its tempo, where its beats fall and its key.
/// `feed` runs on the audio thread and stays cheap; `analyze` does the rest on another thread.
final class BeatAnalyzer {
    struct Beats: Equatable {
        /// Samples between beats.
        let period: Double
        /// Where one beat falls, counted in the samples given to `feed`.
        let origin: Double
        /// Autocorrelation at the beat relative to the whole: below ~0.1 it's guessing.
        let confidence: Double

        func bpm(sampleRate: Double) -> Double { 60 * sampleRate / period }
    }

    struct Estimate {
        var beats: Beats?
        /// Energy per pitch class (C first) since the track started.
        var chroma = [Double](repeating: 0, count: 12)
        var heard: Double = 0 // seconds of the track analyzed
        /// Counts analyses, to tell a new estimate from the same one read again.
        var serial = 0
    }

    static let size = 2048
    static let hop = 512
    private static let historyFrames = 4096
    private static let window: Double = 12 // s analyzed for tempo and beats
    private static let shortest: Double = 6 // s needed before guessing
    private static let tempoRange: ClosedRange<Double> = 70...180 // BPM
    private static let pending = 64

    let sampleRate: Double

    private struct Shared {
        var envelope = [Float](repeating: 0, count: BeatAnalyzer.historyFrames)
        var frames = 0 // envelope values written so far
        var validFrom = 0 // the current track starts here
        var chroma = [Double](repeating: 0, count: 12)
        var chromaFrames = 0
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let latest = OSAllocatedUnfairLock<Estimate>(initialState: Estimate())

    // Only touched on the audio thread.
    private let samples: UnsafeMutableBufferPointer<Float> // ring of the last `size` samples, mono
    private var written = 0
    private var sinceFrame = 0
    private let forward = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(BeatAnalyzer.size), .FORWARD)
    private let hann: UnsafeMutableBufferPointer<Float>
    private let frame: UnsafeMutableBufferPointer<Float>
    private let even: UnsafeMutableBufferPointer<Float>
    private let odd: UnsafeMutableBufferPointer<Float>
    private let real: UnsafeMutableBufferPointer<Float>
    private let imaginary: UnsafeMutableBufferPointer<Float>
    private let magnitude: UnsafeMutableBufferPointer<Float>
    private let previous: UnsafeMutableBufferPointer<Float>
    private let pitchClass: [Int] // per bin, -1 outside C2…C7
    private let fluxBins: Int // up to ~6 kHz
    private var pendingFlux = [Float](repeating: 0, count: BeatAnalyzer.pending)
    private var pendingChroma = [Double](repeating: 0, count: 12)
    private var pendingCount = 0
    private var pendingChromaFrames = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let size = Self.size, bins = size / 2
        samples = .allocate(capacity: size)
        hann = .allocate(capacity: size)
        frame = .allocate(capacity: size)
        even = .allocate(capacity: bins)
        odd = .allocate(capacity: bins)
        real = .allocate(capacity: bins)
        imaginary = .allocate(capacity: bins)
        magnitude = .allocate(capacity: bins)
        previous = .allocate(capacity: bins)
        for buffer in [samples, frame, even, odd, real, imaginary, magnitude, previous] {
            buffer.initialize(repeating: 0)
        }
        for index in 0..<size {
            hann[index] = 0.5 - 0.5 * cos(2 * .pi * Float(index) / Float(size))
        }
        let binWidth = sampleRate / Double(size)
        pitchClass = (0..<bins).map { bin in
            let frequency = Double(bin) * binWidth
            guard frequency >= 65, frequency <= 2_100 else { return -1 }
            let note = Int((12 * log2(frequency / 440)).rounded()) + 9 // A is 9 above C
            return (note % 12 + 12) % 12
        }
        fluxBins = min(bins, Int(6_000 / binWidth))
    }

    deinit {
        if let forward { vDSP_DFT_DestroySetup(forward) }
        [samples, hann, frame, even, odd, real, imaginary, magnitude, previous].forEach { $0.deallocate() }
    }

    /// A new track: forget the old one's beats and key.
    func reset() {
        shared.withLock { state in
            state.validFrom = state.frames
            state.chroma = [Double](repeating: 0, count: 12)
            state.chromaFrames = 0
        }
        latest.withLock { $0 = Estimate() }
    }

    var estimate: Estimate {
        latest.withLock { $0 }
    }

    // MARK: - Audio thread

    func feed(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        let size = Self.size
        for index in 0..<frames {
            samples[written % size] = (left[index] + right[index]) / 2
            written += 1
            sinceFrame += 1
            if sinceFrame == Self.hop {
                sinceFrame = 0
                analyzeFrame()
            }
        }
    }

    private func analyzeFrame() {
        guard let forward else { return }
        let size = Self.size, bins = size / 2
        // Oldest sample first.
        for index in 0..<size {
            frame[index] = samples[(written + index) % size] * hann[index]
        }
        frame.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { pairs in
            var split = DSPSplitComplex(realp: even.baseAddress!, imagp: odd.baseAddress!)
            vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(bins))
        }
        vDSP_DFT_Execute(forward, even.baseAddress!, odd.baseAddress!, real.baseAddress!, imaginary.baseAddress!)
        imaginary[0] = 0
        var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
        vDSP_zvabs(&split, 1, magnitude.baseAddress!, 1, vDSP_Length(bins))

        // Spectral flux of the log magnitude: how much louder each frequency got.
        var flux: Float = 0
        for bin in 1..<fluxBins {
            let level = log1p(100 * magnitude[bin])
            flux += max(0, level - previous[bin])
            previous[bin] = level
        }
        for bin in 0..<bins where pitchClass[bin] >= 0 {
            pendingChroma[pitchClass[bin]] += Double(magnitude[bin] * magnitude[bin])
        }
        pendingChromaFrames += 1
        if pendingCount < Self.pending {
            pendingFlux[pendingCount] = flux
            pendingCount += 1
        }

        // Never waits on the analysis thread: what doesn't fit now goes next time.
        let count = pendingCount
        let delivered = shared.withLockIfAvailable { state -> Bool in
            for index in 0..<count {
                state.envelope[state.frames % Self.historyFrames] = pendingFlux[index]
                state.frames += 1
            }
            for pitch in 0..<12 {
                state.chroma[pitch] += pendingChroma[pitch]
            }
            state.chromaFrames += pendingChromaFrames
            return true
        } ?? false
        if delivered {
            pendingCount = 0
            pendingChromaFrames = 0
            for pitch in 0..<12 { pendingChroma[pitch] = 0 }
        }
    }

    // MARK: - Analysis

    /// Call from a background thread, every half second or so.
    func analyze() {
        let snapshot = shared.withLock { state -> (envelope: [Float], first: Int, chroma: [Double], chromaFrames: Int) in
            let available = min(state.frames - state.validFrom, Self.historyFrames)
            let first = state.frames - available
            var envelope = [Float](repeating: 0, count: available)
            for index in 0..<available {
                envelope[index] = state.envelope[(first + index) % Self.historyFrames]
            }
            return (envelope, first, state.chroma, state.chromaFrames)
        }
        let hopSeconds = Double(Self.hop) / sampleRate
        var estimate = Estimate()
        estimate.serial = latest.withLock { $0.serial } + 1
        estimate.chroma = snapshot.chroma
        estimate.heard = Double(snapshot.chromaFrames) * hopSeconds

        let wanted = Int(Self.window / hopSeconds)
        if snapshot.envelope.count >= Int(Self.shortest / hopSeconds) {
            let envelope = Array(snapshot.envelope.suffix(wanted))
            let first = snapshot.first + snapshot.envelope.count - envelope.count
            estimate.beats = beats(in: envelope, firstFrame: first, hopSeconds: hopSeconds)
        }
        let result = estimate
        latest.withLock { $0 = result }
    }

    private func beats(in raw: [Float], firstFrame: Int, hopSeconds: Double) -> Beats? {
        let count = raw.count
        // Onsets stand out from the local average; the rest is noise.
        let span = max(1, Int(0.25 / hopSeconds))
        var envelope = [Double](repeating: 0, count: count)
        var running: Double = 0
        for index in 0..<count {
            running += Double(raw[index])
            if index >= span { running -= Double(raw[index - span]) }
            let average = running / Double(min(index + 1, span))
            envelope[index] = max(0, Double(raw[index]) - average)
        }

        let shortestLag = Int(60 / Self.tempoRange.upperBound / hopSeconds)
        let longestLag = Int(60 / Self.tempoRange.lowerBound / hopSeconds) + 1
        guard count > 2 * longestLag + 2 else { return nil }
        func correlation(_ lag: Int) -> Double {
            guard lag < count else { return 0 }
            var sum: Double = 0
            for index in lag..<count { sum += envelope[index] * envelope[index - lag] }
            return sum / Double(count - lag)
        }
        let energy = correlation(0)
        guard energy > 0 else { return nil }
        let correlations = (0...(2 * longestLag + 1)).map(correlation)

        // Favor tempos near 120 and lags whose double also lines up, so half-time doesn't win.
        var best = shortestLag, bestScore = -Double.infinity
        for lag in shortestLag...longestLag {
            let bpm = 60 / (Double(lag) * hopSeconds)
            let prior = exp(-0.5 * pow(log2(bpm / 120) / 0.8, 2))
            let score = (correlations[lag] + 0.5 * correlations[2 * lag]) * prior
            if score > bestScore {
                bestScore = score
                best = lag
            }
        }
        let lag = Double(best) + Self.peakOffset(correlations[best - 1], correlations[best], correlations[best + 1])

        // Phase: the offset whose comb of beats, back from the newest frame, collects the most onsets.
        let combCount = min(24, Int(Double(count - 1) / lag))
        var bestPhase = 0, bestSum = -Double.infinity
        var phaseSums = [Double](repeating: 0, count: Int(lag.rounded(.up)) + 1)
        for phase in 0..<phaseSums.count {
            var sum: Double = 0
            for beat in 0..<combCount {
                sum += Self.sample(envelope, at: Double(count - 1 - phase) - Double(beat) * lag)
            }
            phaseSums[phase] = sum
            if sum > bestSum {
                bestSum = sum
                bestPhase = phase
            }
        }
        var newest = Double(count - 1 - bestPhase)
        if bestPhase > 0 && bestPhase < phaseSums.count - 1 {
            newest += Self.peakOffset(phaseSums[bestPhase + 1], phaseSums[bestPhase], phaseSums[bestPhase - 1])
        }

        // Refine both from the onsets themselves: a weighted line through each beat's peak.
        var weights = 0.0, sumK = 0.0, sumP = 0.0, sumKK = 0.0, sumKP = 0.0
        let reach = 0.15 * lag
        for beat in 0..<combCount {
            let expected = newest - Double(beat) * lag
            let low = max(0, Int((expected - reach).rounded(.up))), high = min(count - 1, Int(expected + reach))
            guard low < high else { continue }
            var peak = low
            for index in low...high where envelope[index] > envelope[peak] { peak = index }
            guard envelope[peak] > 0, peak > 0, peak < count - 1 else { continue }
            let position = Double(peak) + Self.peakOffset(envelope[peak - 1], envelope[peak], envelope[peak + 1])
            let weight = envelope[peak]
            let k = Double(beat)
            weights += weight
            sumK += weight * k
            sumP += weight * position
            sumKK += weight * k * k
            sumKP += weight * k * position
        }
        var period = lag
        let denominator = weights * sumKK - sumK * sumK
        if weights > 0, denominator > 1e-9 {
            let slope = (weights * sumKP - sumK * sumP) / denominator // negative: positions fall going back
            let intercept = (sumP - slope * sumK) / weights
            if abs(-slope - lag) < 0.05 * lag {
                period = -slope
                newest = intercept
            }
        }

        // Frame i covers the `size` samples ending at (first + i + 1) × hop: its center is the moment.
        let hop = Double(Self.hop)
        let origin = (Double(firstFrame) + newest + 1) * hop - Double(Self.size) / 2
        return Beats(period: period * hop, origin: origin, confidence: correlations[best] / energy)
    }

    /// Where the top of a parabola through three points lies, from -0.5 to 0.5 around the middle one.
    private static func peakOffset(_ before: Double, _ middle: Double, _ after: Double) -> Double {
        let curve = before - 2 * middle + after
        guard curve < 0 else { return 0 }
        return min(max(0.5 * (before - after) / curve, -0.5), 0.5)
    }

    private static func sample(_ values: [Double], at position: Double) -> Double {
        guard position >= 0 else { return 0 }
        let index = Int(position)
        guard index + 1 < values.count else { return index < values.count ? values[index] : 0 }
        let fraction = position - Double(index)
        return values[index] * (1 - fraction) + values[index + 1] * fraction
    }
}

/// Keys from pitch-class energy (Krumhansl–Kessler profiles), and how far to shift one song to suit another.
enum MusicalKey {
    private static let major: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
    private static let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

    static func name(of chroma: [Double]) -> String? {
        guard chroma.reduce(0, +) > 0 else { return nil }
        var best = (score: -Double.infinity, tonic: 0, isMinor: false)
        for tonic in 0..<12 {
            for isMinor in [false, true] {
                let score = correlation(chroma, rotated(isMinor ? minor : major, by: tonic))
                if score > best.score { best = (score, tonic, isMinor) }
            }
        }
        return names[best.tonic] + (best.isMinor ? "m" : "")
    }

    static func name(of chroma: [Double], shiftedBy semitones: Int) -> String? {
        name(of: rotated(chroma, by: semitones))
    }

    /// Semitones to move `song` so its notes best match `target`'s; small moves win ties, as they sound better.
    static func shift(_ song: [Double], toSuit target: [Double], range: ClosedRange<Int> = -5...6) -> Int {
        var best = (score: -Double.infinity, shift: 0)
        for shift in range {
            let score = correlation(rotated(song, by: shift), target) - 0.02 * Double(abs(shift))
            if score > best.score { best = (score, shift) }
        }
        return best.shift
    }

    private static func rotated(_ values: [Double], by shift: Int) -> [Double] {
        (0..<12).map { values[((($0 - shift) % 12) + 12) % 12] }
    }

    private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let meanA = a.reduce(0, +) / 12, meanB = b.reduce(0, +) / 12
        var sum = 0.0, squaresA = 0.0, squaresB = 0.0
        for index in 0..<12 {
            let x = a[index] - meanA, y = b[index] - meanB
            sum += x * y
            squaresA += x * x
            squaresB += y * y
        }
        return squaresA > 0 && squaresB > 0 ? sum / (squaresA * squaresB).squareRoot() : 0
    }
}
