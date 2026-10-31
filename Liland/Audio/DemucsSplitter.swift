import Accelerate
import AVFoundation
import CoreML
import os

/// Splits stereo music into vocals, bass and drums with HTDemucs, a neural network trained on
/// songs recorded part by part (Meta's Hybrid Transformer Demucs, MIT license), run by Core ML
/// on the GPU. `StemSplitter` can only guess the parts from how they look in a spectrogram;
/// this one has learned what they sound like.
///
/// The network needs to hear a stretch of music, so every `hop` it gets the last second of it
/// (`window`), and only the stretch of its answer that ends `ahead` before the newest sample is
/// kept, crossfaded with the one kept before. Each sample is so separated knowing a second of
/// what came before it and at least `ahead` of what follows, and the parts come out `latency`
/// late: under a third of a second.
///
/// The network takes longer than an audio buffer lasts, so it runs on a thread of its own:
/// `process` only hands it the music and takes back what's ready, without ever waiting for it.
/// What isn't ready in time comes out silent, which happens when the GPU, shared with the
/// screen and the browser, now and then stalls for a few tenths of a second. It always
/// separates all three parts, so changing the ones kept is instant. Not thread-safe: feed it
/// from one thread.
final class DemucsSplitter {
    typealias Parts = StemSplitter.Parts

    /// The network's sample rate, and its spectrogram: frames of `fftSize` samples every
    /// `fftHop`, without the top frequency.
    fileprivate static let rate: Double = 44_100
    fileprivate static let fftSize = 4096
    fileprivate static let fftHop = 1024
    fileprivate static let bins = 2048
    fileprivate static let frames = 44
    /// The music the network hears at once: about a second.
    fileprivate static let window = frames * fftHop
    /// How often the network runs (93 ms), how much of what follows a sample is heard before
    /// it's separated (93 ms), and how long consecutive stretches crossfade (23 ms).
    fileprivate static let hop = 4096
    fileprivate static let ahead = 4096
    fileprivate static let fade = 1024
    /// Seconds left for the network to finish on top of that, once the window's last audio
    /// buffer is in: on an M5 it takes about 20 ms, and up to 50 ms while the browser uses the GPU.
    fileprivate static let margin = 0.08
    /// Where each of `Parts` (vocals, bass, drums) is among the network's sources (drums,
    /// bass, other, vocals).
    fileprivate static let sources = [3, 1, 0]
    /// Samples over which the parts fade out when they're about to run out, because the
    /// network is late, and back in once they're there again, so a gap doesn't click.
    private static let ramp = 256

    /// Apple silicon runs the network several times faster than it needs to; Intel Macs keep `StemSplitter`.
    static var isSupported: Bool {
        #if arch(arm64)
        modelURL != nil
        #else
        false
        #endif
    }

    private static var modelURL: URL? {
        Bundle.main.url(forResource: "HTDemucs", withExtension: "mlmodelc")
    }

    /// The network, loaded once for the whole app by the first worker that needs it.
    fileprivate static let network: MLModel? = {
        guard let url = modelURL else {
            NSLog("Liland: the HTDemucs model is missing")
            return nil
        }
        let configuration = MLModelConfiguration()
        // On the Neural Engine some of its half-precision sums overflow and the parts come out wrong.
        configuration.computeUnits = .cpuAndGPU
        do {
            let started = CFAbsoluteTimeGetCurrent()
            let model = try MLModel(contentsOf: url, configuration: configuration)
            // The first run sets up the GPU and takes seconds, so it's done now rather than
            // on the music.
            let silence = try MLDictionaryFeatureProvider(dictionary: [
                "spectrum": MLMultiArray(shape: [1, 4, bins, frames].map { $0 as NSNumber }, dataType: .float32),
                "wave": MLMultiArray(shape: [1, 2, window].map { $0 as NSNumber }, dataType: .float32),
            ])
            _ = try model.prediction(from: silence)
            NSLog("Liland: HTDemucs ready in %.1f s", CFAbsoluteTimeGetCurrent() - started)
            return model
        } catch {
            NSLog("Liland: could not load the HTDemucs model: \(error)")
            return nil
        }
    }()

    /// Keeps two workers (an old one finishing while a new one starts) from running the network at once.
    fileprivate static let predicting = NSLock()

    /// How many samples the parts lag behind the music.
    let latency: Int
    /// Samples played silent because their parts weren't ready in time.
    private(set) var missed = 0

    private let exchange = Exchange()
    private var written = 0
    private var restart = 0
    private var produced = 0
    private var origin = 0
    private var hasFailed = false
    /// How loud the parts are played, from 0 to 1, to fade around gaps.
    private var gain: Float = 0

    init?(sampleRate: Double) {
        guard sampleRate > 0 else { return nil }
        latency = Int((Double(Self.ahead + Self.hop + Self.fade) / Self.rate + Self.margin) * sampleRate)
        guard let worker = Worker(exchange: exchange, sampleRate: sampleRate) else { return nil }
        let thread = Thread { worker.run() }
        thread.name = "Liland.DemucsSplitter"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    deinit {
        exchange.state.withLock { $0.isStopping = true }
        exchange.wakeUp.signal()
    }

    /// Starts over, for music that doesn't follow what came before.
    func reset() {
        restart = written
    }

    /// Replaces the samples of both channels, in place, with the parts to keep, `latency` later.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, keeping parts: Parts) {
        let capacity = Exchange.capacity, wrap = capacity - 1
        for index in 0..<frames {
            let slot = (written + index) & wrap
            exchange.input[slot] = left[index]
            exchange.input[capacity + slot] = right[index]
        }
        let first = written - latency
        written += frames
        // Never waits: if the worker happens to hold the lock, it hears of this music next time.
        let written = written, restart = restart
        if let state = exchange.state.withLockIfAvailable({ state -> Exchange.State in
            state.written = written
            state.restart = restart
            return state
        }) {
            produced = state.produced
            origin = state.origin
            hasFailed = state.hasFailed
        }
        exchange.wakeUp.signal()
        // Without the network, the whole song rather than nothing.
        guard !hasFailed else { return }

        let start = max(restart, origin)
        let step = 1 / Float(Self.ramp)
        for index in 0..<frames {
            let position = first + index
            var leftSum: Float = 0, rightSum: Float = 0
            if position >= start && position < produced {
                // On time, the parts are ready well ahead of `position`: tens of milliseconds.
                gain = produced - position > Self.ramp ? min(gain + step, 1) : max(gain - step, 0)
                let slot = position & wrap
                for part in 0..<Self.sources.count where parts.contains(Parts(rawValue: UInt8(1 << part))) {
                    leftSum += exchange.output[2 * part * capacity + slot]
                    rightSum += exchange.output[(2 * part + 1) * capacity + slot]
                }
            } else {
                if position >= start { missed += 1 }
                gain = 0
            }
            left[index] = leftSum * gain
            right[index] = rightSum * gain
        }
    }
}

/// What the audio thread and the worker hand each other.
private final class Exchange {
    struct State {
        /// Samples of music written to `input`, by the audio thread.
        var written = 0
        /// Where the music last started again: what came before it is another stretch of music.
        var restart = 0
        /// Samples of parts written to `output`, by the worker, from `origin` on.
        var produced = 0
        var origin = 0
        var isStopping = false
        var hasFailed = false
    }

    /// Positions in `input` and `output` wrap around after this many samples (about 5 s at 48 kHz).
    static let capacity = 1 << 18

    let state = OSAllocatedUnfairLock(initialState: State())
    /// Signaled whenever music is written.
    let wakeUp = DispatchSemaphore(value: 0)
    /// The music at the device's rate: its left channel, then its right.
    let input = UnsafeMutableBufferPointer<Float>.allocate(capacity: 2 * capacity)
    /// The parts at the device's rate, in the order of `Parts`: each one's left channel, then its right.
    let output = UnsafeMutableBufferPointer<Float>.allocate(capacity: 2 * DemucsSplitter.sources.count * capacity)

    init() {
        input.initialize(repeating: 0)
        output.initialize(repeating: 0)
    }

    deinit {
        input.deallocate()
        output.deallocate()
    }
}

/// Runs the network on its own thread, from the music in `exchange.input` to the parts in `exchange.output`.
private final class Worker {
    private typealias Splitter = DemucsSplitter

    /// The most music, in samples at the network's rate, kept to make up the next windows.
    private static let musicCapacity = 1 << 17
    /// Device samples taken from `exchange.input` at a time.
    private static let chunk = 4096
    /// Where each stretch kept starts and ends in the window, and which spectrogram frames cover it.
    private static let regionStart = Splitter.window - Splitter.ahead - Splitter.hop - Splitter.fade
    private static let regionLength = Splitter.hop + Splitter.fade
    private static let firstFrame = max(0, (regionStart - (Splitter.fftSize - frameOffset)) / Splitter.fftHop + 1)
    private static let lastFrame = min(Splitter.frames - 1, (regionStart + regionLength + frameOffset - 1) / Splitter.fftHop)
    /// The spectrogram's frame `t` starts at `t * fftHop - frameOffset`, mirroring the music
    /// past the window's edges, as HTDemucs pads it.
    private static let frameOffset = Splitter.fftHop / 2 * 3
    /// Network runs timed before saying how long they take.
    private static let timedRuns = 100
    /// A window this late (at the network's rate) would come out entirely after its time.
    private static let lateness = Splitter.hop + Int(Splitter.margin * Splitter.rate)

    private let exchange: Exchange
    /// When the device's rate isn't the network's, the music on its way in, and each part on its way out.
    private let toNetwork: RateConverter?
    private let fromNetwork: [RateConverter]

    // Positions at the device's rate.
    private var lastRestart = 0
    private var consumed = 0
    private var produced = 0
    // Positions at the network's rate, from where the music started.
    private var heard = 0
    private var nextEnd = 0

    private let forward = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(Splitter.fftSize), .FORWARD)
    private let inverse = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(Splitter.fftSize), .INVERSE)
    private let analysisWindow: UnsafeMutableBufferPointer<Float>
    /// The same Hann window, scaled to undo the transforms' scaling and the frames' overlap.
    private let synthesisWindow: UnsafeMutableBufferPointer<Float>
    /// Fades each stretch in over its first `fade` samples and out over its last.
    private let crossfade: UnsafeMutableBufferPointer<Float>

    /// The music at the network's rate, its left channel then its right, in a circle.
    private let music: UnsafeMutableBufferPointer<Float>
    private let frame: UnsafeMutableBufferPointer<Float>
    private let evenSamples: UnsafeMutableBufferPointer<Float>
    private let oddSamples: UnsafeMutableBufferPointer<Float>
    private let real: UnsafeMutableBufferPointer<Float>
    private let imaginary: UnsafeMutableBufferPointer<Float>
    /// The stretch being kept, then the end of the one before, for each part's left and right.
    private let region: UnsafeMutableBufferPointer<Float>
    private let tail: UnsafeMutableBufferPointer<Float>
    private let scratch: UnsafeMutableBufferPointer<Float>

    // The network's inputs and outputs, written and read in place.
    private let spectrum: UnsafeMutableBufferPointer<Float>
    private let wave: UnsafeMutableBufferPointer<Float>
    private let spectra: UnsafeMutableBufferPointer<Float>
    private let waves: UnsafeMutableBufferPointer<Float>
    private let inputs: MLFeatureProvider
    private let options = MLPredictionOptions()

    private var runs = 0
    private var runTime = 0.0
    private var longestRun = 0.0
    private var skipped = 0
    private var lastSkipReport = 0.0

    init?(exchange: Exchange, sampleRate: Double) {
        self.exchange = exchange
        if sampleRate == Splitter.rate {
            toNetwork = nil
            fromNetwork = []
        } else {
            guard let toNetwork = RateConverter(from: sampleRate, to: Splitter.rate, frames: Self.chunk) else { return nil }
            let fromNetwork = Splitter.sources.compactMap { _ in
                RateConverter(from: Splitter.rate, to: sampleRate, frames: Splitter.hop)
            }
            guard fromNetwork.count == Splitter.sources.count else { return nil }
            self.toNetwork = toNetwork
            self.fromNetwork = fromNetwork
        }

        let size = Splitter.fftSize, bins = Splitter.bins, frames = Splitter.frames, window = Splitter.window
        analysisWindow = .allocate(capacity: size)
        synthesisWindow = .allocate(capacity: size)
        for index in 0..<size {
            let hann = 0.5 - 0.5 * cos(2 * .pi * Float(index) / Float(size))
            analysisWindow[index] = hann
            // The inverse transform comes out `size` times the music, HTDemucs scales its spectrum
            // back up by √size, and its frames' squared windows add up to 1.5: together, 1 / 96.
            synthesisWindow[index] = hann * Float(size).squareRoot() / (Float(size) * 1.5)
        }
        crossfade = .allocate(capacity: Self.regionLength)
        for index in 0..<Self.regionLength {
            let fade = Float(Splitter.fade)
            if index < Splitter.fade {
                crossfade[index] = pow(sin(.pi / 2 * (Float(index) + 0.5) / fade), 2)
            } else if index >= Splitter.hop {
                crossfade[index] = pow(cos(.pi / 2 * (Float(index - Splitter.hop) + 0.5) / fade), 2)
            } else {
                crossfade[index] = 1
            }
        }

        music = .allocate(capacity: 2 * Self.musicCapacity)
        frame = .allocate(capacity: size)
        evenSamples = .allocate(capacity: bins)
        oddSamples = .allocate(capacity: bins)
        real = .allocate(capacity: bins)
        imaginary = .allocate(capacity: bins)
        let channels = 2 * Splitter.sources.count
        region = .allocate(capacity: channels * Self.regionLength)
        tail = .allocate(capacity: channels * Splitter.fade)
        scratch = .allocate(capacity: Self.regionLength)
        spectrum = .allocate(capacity: 4 * bins * frames)
        wave = .allocate(capacity: 2 * window)
        spectra = .allocate(capacity: 16 * bins * frames)
        waves = .allocate(capacity: 8 * window)
        for buffer in [music, region, tail, spectrum, wave, spectra, waves] {
            buffer.initialize(repeating: 0)
        }

        func array(_ buffer: UnsafeMutableBufferPointer<Float>, _ shape: [Int]) throws -> MLMultiArray {
            let strides = shape.indices.map { shape[($0 + 1)...].reduce(1, *) }
            return try MLMultiArray(
                dataPointer: buffer.baseAddress!,
                shape: shape.map { $0 as NSNumber },
                dataType: .float32,
                strides: strides.map { $0 as NSNumber }
            )
        }
        do {
            inputs = try MLDictionaryFeatureProvider(dictionary: [
                "spectrum": array(spectrum, [1, 4, bins, frames]),
                "wave": array(wave, [1, 2, window]),
            ])
            options.outputBackings = [
                "spectra": try array(spectra, [1, 16, bins, frames]),
                "waves": try array(waves, [1, 8, window]),
            ]
        } catch {
            NSLog("Liland: could not set up the HTDemucs buffers: \(error)")
            return nil
        }
    }

    deinit {
        if let forward { vDSP_DFT_DestroySetup(forward) }
        if let inverse { vDSP_DFT_DestroySetup(inverse) }
        [analysisWindow, synthesisWindow, crossfade, music, frame, evenSamples, oddSamples, real, imaginary,
         region, tail, scratch, spectrum, wave, spectra, waves]
            .forEach { $0.deallocate() }
    }

    func run() {
        // Loaded before the first part is chosen, so it's ready then.
        let network = Splitter.network
        if let network {
            // The first run into these buffers is slower too: also done before the music.
            Splitter.predicting.withLock {
                _ = try? network.prediction(from: inputs, options: options)
            }
        } else {
            exchange.state.withLock { $0.hasFailed = true }
        }
        // The music written while it loaded is already late: start from the newest.
        let loaded = exchange.state.withLock { $0 }
        lastRestart = loaded.restart
        start(at: loaded.written)
        while true {
            exchange.wakeUp.wait()
            let state = exchange.state.withLock { $0 }
            if state.isStopping { return }
            guard let network else { continue }

            if state.restart != lastRestart {
                lastRestart = state.restart
                start(at: state.restart)
            } else if state.written - consumed > Exchange.capacity / 2 {
                // Seconds behind (the Mac slept): the music left is too old to bother with.
                start(at: state.written)
            }
            take(upTo: state.written)
            while heard >= nextEnd {
                // After the GPU stalled, the windows that would come out after their time are
                // skipped, so the next one is on time again.
                if heard - nextEnd > Self.lateness {
                    skip()
                } else {
                    separate(endingAt: nextEnd, with: network)
                }
                nextEnd += Splitter.hop
                let produced = produced
                exchange.state.withLock { $0.produced = produced }
            }
        }
    }

    /// Starts a new stretch of music at `position`: what came before is forgotten, and its parts
    /// come out at the same position, so they line up with the music.
    private func start(at position: Int) {
        consumed = position
        produced = position
        heard = 0
        // The first window ends where the first stretch kept starts at the music's first sample.
        nextEnd = Splitter.ahead + Splitter.hop + Splitter.fade
        tail.update(repeating: 0)
        toNetwork?.reset()
        fromNetwork.forEach { $0.reset() }
        exchange.state.withLock {
            $0.origin = position
            $0.produced = position
        }
    }

    /// Moves the music written since last time into `music`, at the network's rate.
    private func take(upTo written: Int) {
        let capacity = Exchange.capacity, wrap = capacity - 1
        while consumed < written {
            let count = min(written - consumed, Self.chunk)
            if let toNetwork {
                let left = toNetwork.input.floatChannelData![0], right = toNetwork.input.floatChannelData![1]
                for index in 0..<count {
                    let slot = (consumed + index) & wrap
                    left[index] = exchange.input[slot]
                    right[index] = exchange.input[capacity + slot]
                }
                let converted = toNetwork.convert(frames: count)
                let channels = toNetwork.output.floatChannelData!
                append(left: channels[0], right: channels[1], count: converted)
            } else {
                for index in 0..<count {
                    let slot = (consumed + index) & wrap
                    let at = (heard + index) & (Self.musicCapacity - 1)
                    music[at] = exchange.input[slot]
                    music[Self.musicCapacity + at] = exchange.input[capacity + slot]
                }
                heard += count
            }
            consumed += count
        }
    }

    private func append(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        for index in 0..<count {
            let at = (heard + index) & (Self.musicCapacity - 1)
            music[at] = left[index]
            music[Self.musicCapacity + at] = right[index]
        }
        heard += count
    }

    /// Runs the network on the window ending at `end` and writes out the next `hop` of each part.
    private func separate(endingAt end: Int, with network: MLModel) {
        let started = CFAbsoluteTimeGetCurrent()
        let window = Splitter.window, frames = Splitter.frames, bins = Splitter.bins
        let plane = bins * frames
        // Before the music started, silence.
        for channel in 0..<2 {
            for index in 0..<window {
                let position = end - window + index
                wave[channel * window + index] = position < 0
                    ? 0 : music[channel * Self.musicCapacity + (position & (Self.musicCapacity - 1))]
            }
        }

        transform()
        let (spectrumDeviation, spectrumMean) = Self.normalize(spectrum)
        let (waveDeviation, waveMean) = Self.normalize(wave)
        do {
            Splitter.predicting.lock()
            defer { Splitter.predicting.unlock() }
            _ = try network.prediction(from: inputs, options: options)
        } catch {
            NSLog("Liland: HTDemucs failed: \(error)")
            spectra.update(repeating: 0)
            waves.update(repeating: 0)
        }

        let length = Self.regionLength
        var scale = spectrumDeviation, shift = spectrumMean
        var waveScale = waveDeviation, waveShift = waveMean
        for (part, source) in Splitter.sources.enumerated() {
            for channel in 0..<2 {
                let output = region.baseAddress! + (2 * part + channel) * length
                output.update(repeating: 0, count: length)
                // The spectrogram's half, back into sound frame by frame.
                for time in Self.firstFrame...Self.lastFrame {
                    let realPlane = spectra.baseAddress! + (4 * source + 2 * channel) * plane + time
                    vDSP_vsmsa(realPlane, vDSP_Stride(frames), &scale, &shift, real.baseAddress!, 1, vDSP_Length(bins))
                    vDSP_vsmsa(realPlane + plane, vDSP_Stride(frames), &scale, &shift, imaginary.baseAddress!, 1, vDSP_Length(bins))
                    // That slot holds the top frequency, which the network doesn't make.
                    imaginary[0] = 0
                    inverseTransform()
                    let offset = time * Splitter.fftHop - Self.frameOffset - Self.regionStart
                    let from = max(0, -offset), to = min(Splitter.fftSize, length - offset)
                    guard from < to else { continue }
                    let count = vDSP_Length(to - from)
                    vDSP_vmul(frame.baseAddress! + from, 1, synthesisWindow.baseAddress! + from, 1, frame.baseAddress! + from, 1, count)
                    vDSP_vadd(frame.baseAddress! + from, 1, output + offset + from, 1, output + offset + from, 1, count)
                }
                // Plus the half the network made as a wave.
                let wavePlane = waves.baseAddress! + (2 * source + channel) * window + Self.regionStart
                vDSP_vsmsa(wavePlane, 1, &waveScale, &waveShift, scratch.baseAddress!, 1, vDSP_Length(length))
                vDSP_vadd(scratch.baseAddress!, 1, output, 1, output, 1, vDSP_Length(length))
            }
        }
        write()

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        if runs < Self.timedRuns {
            runs += 1
            runTime += elapsed
            longestRun = max(longestRun, elapsed)
            if runs == Self.timedRuns {
                NSLog(
                    "Liland: separating takes %.0f ms on average (at most %.0f) for every %.0f ms of music",
                    runTime / Double(runs) * 1000, longestRun * 1000, Double(Splitter.hop) / Splitter.rate * 1000
                )
            }
        }
    }

    /// Silence instead of a window that came too late, so the stretch before fades out.
    private func skip() {
        region.update(repeating: 0)
        write()
        skipped += 1
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSkipReport > 10 else { return }
        lastSkipReport = now
        NSLog(
            "Liland: separating fell behind the music, %.0f ms of it came out silent",
            Double(skipped * Splitter.hop) / Splitter.rate * 1000
        )
        skipped = 0
    }

    /// Crossfades each part's stretch with the end of the one before, and writes its first
    /// `hop` to `exchange.output`, at the device's rate.
    private func write() {
        let capacity = Exchange.capacity, wrap = capacity - 1, length = Self.regionLength
        for channel in 0..<(2 * Splitter.sources.count) {
            let output = region.baseAddress! + channel * length
            vDSP_vmul(output, 1, crossfade.baseAddress!, 1, output, 1, vDSP_Length(length))
            let previous = tail.baseAddress! + channel * Splitter.fade
            vDSP_vadd(previous, 1, output, 1, output, 1, vDSP_Length(Splitter.fade))
            previous.update(from: output + Splitter.hop, count: Splitter.fade)
        }

        var count = Splitter.hop
        if !fromNetwork.isEmpty {
            // They all get the same music and come out the same length.
            count = .max
            for (part, converter) in fromNetwork.enumerated() {
                for channel in 0..<2 {
                    converter.input.floatChannelData![channel].update(
                        from: region.baseAddress! + (2 * part + channel) * length,
                        count: Splitter.hop
                    )
                }
                count = min(count, converter.convert(frames: Splitter.hop))
            }
        }
        for part in 0..<Splitter.sources.count {
            for channel in 0..<2 {
                let source = fromNetwork.isEmpty
                    ? UnsafePointer(region.baseAddress! + (2 * part + channel) * length)
                    : UnsafePointer(fromNetwork[part].output.floatChannelData![channel])
                let base = (2 * part + channel) * capacity
                for index in 0..<count {
                    exchange.output[base + ((produced + index) & wrap)] = source[index]
                }
            }
        }
        produced += count
    }

    /// HTDemucs's spectrogram of `wave`: each channel's real and imaginary parts as planes of
    /// `bins` by `frames`, scaled by 1/√fftSize.
    private func transform() {
        guard let forward else { return }
        let window = Splitter.window, size = Splitter.fftSize, bins = Splitter.bins, frames = Splitter.frames
        let plane = bins * frames
        var scale = 1 / (2 * Float(size).squareRoot())
        for channel in 0..<2 {
            let samples = wave.baseAddress! + channel * window
            for time in 0..<frames {
                let start = time * Splitter.fftHop - Self.frameOffset
                for index in 0..<size {
                    var position = start + index
                    if position < 0 {
                        position = -position
                    } else if position >= window {
                        position = 2 * (window - 1) - position
                    }
                    frame[index] = samples[position] * analysisWindow[index]
                }
                frame.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { pairs in
                    var split = DSPSplitComplex(realp: evenSamples.baseAddress!, imagp: oddSamples.baseAddress!)
                    vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(bins))
                }
                vDSP_DFT_Execute(forward, evenSamples.baseAddress!, oddSamples.baseAddress!, real.baseAddress!, imaginary.baseAddress!)
                // That slot holds the top frequency, which HTDemucs drops.
                imaginary[0] = 0
                let realPlane = spectrum.baseAddress! + 2 * channel * plane + time
                vDSP_vsmul(real.baseAddress!, 1, &scale, realPlane, vDSP_Stride(frames), vDSP_Length(bins))
                vDSP_vsmul(imaginary.baseAddress!, 1, &scale, realPlane + plane, vDSP_Stride(frames), vDSP_Length(bins))
            }
        }
    }

    /// One frame of `real` and `imaginary` back into `frame`.
    private func inverseTransform() {
        guard let inverse else { return }
        vDSP_DFT_Execute(inverse, real.baseAddress!, imaginary.baseAddress!, evenSamples.baseAddress!, oddSamples.baseAddress!)
        frame.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Splitter.bins) { pairs in
            var split = DSPSplitComplex(realp: evenSamples.baseAddress!, imagp: oddSamples.baseAddress!)
            vDSP_ztoc(&split, 1, pairs, 2, vDSP_Length(Splitter.bins))
        }
    }

    /// Shifts and scales `values` to a mean of 0 and a standard deviation of about 1, as HTDemucs
    /// does before the network, and returns the deviation and mean to undo it after.
    private static func normalize(_ values: UnsafeMutableBufferPointer<Float>) -> (deviation: Float, mean: Float) {
        let count = vDSP_Length(values.count)
        var mean: Float = 0, meanSquare: Float = 0
        vDSP_meanv(values.baseAddress!, 1, &mean, count)
        vDSP_measqv(values.baseAddress!, 1, &meanSquare, count)
        let variance = max(0, meanSquare - mean * mean) * Float(values.count) / Float(values.count - 1)
        let deviation = variance.squareRoot()
        var shift = -mean, scale = 1 / (1e-5 + deviation)
        vDSP_vsadd(values.baseAddress!, 1, &shift, values.baseAddress!, 1, count)
        vDSP_vsmul(values.baseAddress!, 1, &scale, values.baseAddress!, 1, count)
        return (deviation, mean)
    }
}

/// Changes the sample rate of a stream of stereo music, keeping what it holds back between calls.
private final class RateConverter {
    let input: AVAudioPCMBuffer
    let output: AVAudioPCMBuffer
    private let converter: AVAudioConverter

    init?(from source: Double, to destination: Double, frames: Int) {
        guard let from = AVAudioFormat(standardFormatWithSampleRate: source, channels: 2),
              let to = AVAudioFormat(standardFormatWithSampleRate: destination, channels: 2),
              let converter = AVAudioConverter(from: from, to: to),
              let input = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: AVAudioFrameCount(frames)),
              // Room for all of it, so it never holds input back for lack of space.
              let output = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: AVAudioFrameCount(Double(frames) * destination / source * 1.1) + 256)
        else { return nil }
        // Unprimed, it starts right away and comes out a few samples late, as a stream should.
        converter.primeMethod = .none
        self.converter = converter
        self.input = input
        self.output = output
    }

    /// Converts the first `frames` of `input` into `output`, and returns how many came out.
    func convert(frames: Int) -> Int {
        input.frameLength = AVAudioFrameCount(frames)
        output.frameLength = 0
        var isGiven = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if isGiven {
                inputStatus.pointee = .noDataNow
                return nil
            }
            isGiven = true
            inputStatus.pointee = .haveData
            return self.input
        }
        return status == .error ? 0 : Int(output.frameLength)
    }

    func reset() {
        converter.reset()
    }
}
