import Accelerate
import AVFoundation
import CoreML
import os

/// HTDemucs stem splitter on Core ML (GPU); HTDemucs6s masks the guitar out of "other".
/// Networks run on their own thread; parts come out `latency` late. Not thread-safe.
final class DemucsSplitter {
    typealias Parts = StemSplitter.Parts

    fileprivate static let rate: Double = 44_100
    fileprivate static let fftSize = 4096
    fileprivate static let fftHop = 1024
    fileprivate static let bins = 2048 // top frequency dropped
    fileprivate static let hop = 4096 // 93 ms between network runs
    fileprivate static let ahead = 4096 // 93 ms of lookahead
    fileprivate static let fade = 1024 // 23 ms crossfade
    /// Seconds of inference slack: on M5 ~30 ms for HTDemucs, ~45 ms with guitar, up to 70 ms under GPU load.
    fileprivate static let margin = 0.1
    fileprivate static let partCount = 4 // vocals, bass, drums, guitar (bits of Parts)
    private static let ramp = 256 // samples; fades around gaps so they don't click

    /// Intel Macs fall back to `StemSplitter`.
    static var isSupported: Bool {
        #if arch(arm64)
        Network.separating.isBundled
        #else
        false
        #endif
    }

    static var canIsolateGuitar: Bool {
        isSupported && Network.guitar.isBundled
    }

    let latency: Int // samples
    private(set) var missed = 0 // samples played silent: parts not ready in time

    private let exchange = Exchange()
    private var written = 0
    private var restart = 0
    private var produced = 0
    private var origin = 0
    private var hasFailed = false
    private var gain: Float = 0 // 0...1

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

    func reset() {
        restart = written
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, keeping parts: Parts) {
        let capacity = Exchange.capacity, wrap = capacity - 1
        for index in 0..<frames {
            let slot = (written + index) & wrap
            exchange.input[slot] = left[index]
            exchange.input[capacity + slot] = right[index]
        }
        let first = written - latency
        written += frames
        // Real-time thread: never block; if the worker holds the lock it sees this next time.
        let written = written, restart = restart, kept = parts.rawValue
        if let state = exchange.state.withLockIfAvailable({ state -> Exchange.State in
            state.written = written
            state.restart = restart
            state.parts = kept
            return state
        }) {
            produced = state.produced
            origin = state.origin
            hasFailed = state.hasFailed
        }
        exchange.wakeUp.signal()
        // Model failed: pass the original audio through.
        guard !hasFailed else { return }

        let start = max(restart, origin)
        let step = 1 / Float(Self.ramp)
        for index in 0..<frames {
            let position = first + index
            var leftSum: Float = 0, rightSum: Float = 0
            if position >= start && position < produced {
                gain = produced - position > Self.ramp ? min(gain + step, 1) : max(gain - step, 0)
                let slot = position & wrap
                for part in 0..<Self.partCount where parts.contains(Parts(rawValue: UInt8(1 << part))) {
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

private final class Network {
    static let separating = Network(name: "HTDemucs", sources: 4, frames: 44) // sources: drums, bass, other, vocals
    /// Used only for the guitar (its other stems are worse); needs twice the context.
    static let guitar = Network(name: "HTDemucs6s", sources: 6, frames: 88)

    /// Serializes predictions across workers (an old one finishing while a new one starts).
    static let predicting = NSLock()

    let name: String
    let sources: Int
    let frames: Int // spectrogram frames per window

    private let lock = NSLock()
    private let loading = NSLock()
    private var model: MLModel?
    private var hasStarted = false
    private var hasFailed = false

    private init(name: String, sources: Int, frames: Int) {
        self.name = name
        self.sources = sources
        self.frames = frames
    }

    var isBundled: Bool {
        url != nil
    }

    private var url: URL? {
        Bundle.main.url(forResource: name, withExtension: "mlmodelc")
    }

    func loadedModel() -> MLModel? {
        loading.lock()
        defer { loading.unlock() }
        let (model, hasFailed) = lock.withLock { (self.model, self.hasFailed) }
        if model != nil || hasFailed { return model }
        let loaded = load()
        lock.withLock {
            self.model = loaded
            self.hasFailed = loaded == nil
        }
        return loaded
    }

    func modelIfLoaded() -> MLModel? {
        let (model, shouldStart) = lock.withLock { () -> (MLModel?, Bool) in
            let shouldStart = !hasStarted && self.model == nil
            hasStarted = true
            return (self.model, shouldStart)
        }
        if shouldStart {
            DispatchQueue.global(qos: .userInitiated).async { _ = self.loadedModel() }
        }
        return model
    }

    private func load() -> MLModel? {
        guard let url else {
            NSLog("Liland: the %@ model is missing", name)
            return nil
        }
        let configuration = MLModelConfiguration()
        // On the Neural Engine its normalizations amplify rounding errors and the parts come out wrong.
        configuration.computeUnits = .cpuAndGPU
        do {
            let started = CFAbsoluteTimeGetCurrent()
            let model = try MLModel(contentsOf: url, configuration: configuration)
            // The first run sets up the GPU and takes seconds; do it now, not on the music.
            let silence = try MLDictionaryFeatureProvider(dictionary: [
                "spectrum": MLMultiArray(shape: [1, 4, DemucsSplitter.bins, frames].map { $0 as NSNumber }, dataType: .float32),
                "wave": MLMultiArray(shape: [1, 2, frames * DemucsSplitter.fftHop].map { $0 as NSNumber }, dataType: .float32),
            ])
            _ = try model.prediction(from: silence)
            NSLog("Liland: %@ ready in %.1f s", name, CFAbsoluteTimeGetCurrent() - started)
            return model
        } catch {
            NSLog("Liland: could not load the %@ model: \(error)", name)
            return nil
        }
    }
}

private final class Exchange {
    struct State {
        var written = 0
        var restart = 0
        var parts: UInt8 = 0
        var produced = 0
        var origin = 0
        var isStopping = false
        var hasFailed = false
    }

    static let capacity = 1 << 18 // samples, ~5 s at 48 kHz

    let state = OSAllocatedUnfairLock(initialState: State())
    let wakeUp = DispatchSemaphore(value: 0)
    let input = UnsafeMutableBufferPointer<Float>.allocate(capacity: 2 * capacity) // device rate: left, then right
    /// Device rate, in Parts order: each part's left, then right.
    let output = UnsafeMutableBufferPointer<Float>.allocate(capacity: 2 * DemucsSplitter.partCount * capacity)

    init() {
        input.initialize(repeating: 0)
        output.initialize(repeating: 0)
    }

    deinit {
        input.deallocate()
        output.deallocate()
    }
}

private final class Worker {
    private typealias Splitter = DemucsSplitter
    private typealias Parts = DemucsSplitter.Parts

    private final class Run {
        let network: Network
        let frames: Int
        let window: Int
        let regionStart: Int
        let firstFrame: Int
        let lastFrame: Int
        let rawSpectrum: UnsafeMutableBufferPointer<Float> // unnormalized; the next window reuses most of it
        let spectrum: UnsafeMutableBufferPointer<Float>
        let wave: UnsafeMutableBufferPointer<Float>
        let spectra: UnsafeMutableBufferPointer<Float>
        let waves: UnsafeMutableBufferPointer<Float>
        let inputs: MLFeatureProvider
        let options = MLPredictionOptions()
        var model: MLModel?
        var transformedEnd: Int?
        var spectrumScale: Float = 1, spectrumShift: Float = 0
        var waveScale: Float = 1, waveShift: Float = 0

        init(network: Network) throws {
            let bins = Splitter.bins
            self.network = network
            frames = network.frames
            window = frames * Splitter.fftHop
            regionStart = window - Splitter.ahead - Splitter.hop - Splitter.fade
            firstFrame = max(0, (regionStart - (Splitter.fftSize - Worker.frameOffset)) / Splitter.fftHop + 1)
            lastFrame = min(frames - 1, (regionStart + Worker.regionLength + Worker.frameOffset - 1) / Splitter.fftHop)
            rawSpectrum = .allocate(capacity: 4 * bins * frames)
            spectrum = .allocate(capacity: 4 * bins * frames)
            wave = .allocate(capacity: 2 * window)
            spectra = .allocate(capacity: 4 * network.sources * bins * frames)
            waves = .allocate(capacity: 2 * network.sources * window)
            for buffer in [rawSpectrum, spectrum, wave, spectra, waves] {
                buffer.initialize(repeating: 0)
            }
            inputs = try MLDictionaryFeatureProvider(dictionary: [
                "spectrum": try Self.array(spectrum, [1, 4, bins, frames]),
                "wave": try Self.array(wave, [1, 2, window]),
            ])
            options.outputBackings = [
                "spectra": try Self.array(spectra, [1, 4 * network.sources, bins, frames]),
                "waves": try Self.array(waves, [1, 2 * network.sources, window]),
            ]
        }

        deinit {
            [rawSpectrum, spectrum, wave, spectra, waves].forEach { $0.deallocate() }
        }

        private static func array(_ buffer: UnsafeMutableBufferPointer<Float>, _ shape: [Int]) throws -> MLMultiArray {
            let strides = shape.indices.map { shape[($0 + 1)...].reduce(1, *) }
            return try MLMultiArray(
                dataPointer: buffer.baseAddress!,
                shape: shape.map { $0 as NSNumber },
                dataType: .float32,
                strides: strides.map { $0 as NSNumber }
            )
        }
    }

    private static let separatedSources = [3, 1, 0] // HTDemucs vocals, bass, drums
    private static let restSource = 2
    private static let guitarSources = (guitar: 4, piano: 5, rest: 2)
    private static let guitarPart = 3

    private static let musicCapacity = 1 << 17 // samples at the networks' rate
    private static let chunk = 4096 // device samples
    private static let regionLength = Splitter.hop + Splitter.fade
    /// Frame t starts at t * fftHop - frameOffset; past the edges the music is mirrored, as HTDemucs pads.
    private static let frameOffset = Splitter.fftHop / 2 * 3
    private static let firstInnerFrame = (frameOffset + Splitter.fftHop - 1) / Splitter.fftHop
    private static let frameShift = Splitter.hop / Splitter.fftHop
    private static let timedRuns = 100
    private static let lateness = Splitter.hop + Int(Splitter.margin * Splitter.rate) // later windows are skipped
    /// -120 dB: quieter windows are skipped; the answer scales with the input level anyway.
    private static let silence: Float = 1e-6

    private let exchange: Exchange
    private let toNetwork: RateConverter?
    private let fromNetwork: [RateConverter]
    private let separating: Run
    private var guitar: Run?

    // Positions at the device's rate.
    private var lastRestart = 0
    private var consumed = 0
    private var produced = 0
    // Positions at the networks' rate, from where the music started.
    private var heard = 0
    private var nextEnd = 0

    private let forward = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(Splitter.fftSize), .FORWARD)
    private let inverse = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(Splitter.fftSize), .INVERSE)
    private let analysisWindow: UnsafeMutableBufferPointer<Float>
    private let synthesisWindow: UnsafeMutableBufferPointer<Float>
    private let crossfade: UnsafeMutableBufferPointer<Float>

    private let music: UnsafeMutableBufferPointer<Float> // networks' rate, left then right, ring buffer
    private let frame: UnsafeMutableBufferPointer<Float>
    private let evenSamples: UnsafeMutableBufferPointer<Float>
    private let oddSamples: UnsafeMutableBufferPointer<Float>
    private let real: UnsafeMutableBufferPointer<Float>
    private let imaginary: UnsafeMutableBufferPointer<Float>
    /// One frame each: HTDemucs rest, then 6s guitar, piano and rest; and the power of the last three.
    private let slices: UnsafeMutableBufferPointer<Float>
    private let powers: UnsafeMutableBufferPointer<Float>
    private let region: UnsafeMutableBufferPointer<Float>
    private let tail: UnsafeMutableBufferPointer<Float>
    private let scratch: UnsafeMutableBufferPointer<Float>

    private var timedRunCount = 0
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
            let fromNetwork = (0..<Splitter.partCount).compactMap { _ in
                RateConverter(from: Splitter.rate, to: sampleRate, frames: Splitter.hop)
            }
            guard fromNetwork.count == Splitter.partCount else { return nil }
            self.toNetwork = toNetwork
            self.fromNetwork = fromNetwork
        }

        let size = Splitter.fftSize, bins = Splitter.bins
        analysisWindow = .allocate(capacity: size)
        synthesisWindow = .allocate(capacity: size)
        for index in 0..<size {
            let hann = 0.5 - 0.5 * cos(2 * .pi * Float(index) / Float(size))
            analysisWindow[index] = hann
            // iDFT gives size×, HTDemucs scales by √size, squared Hann overlap sums to 1.5: 1/96 total.
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
        slices = .allocate(capacity: 4 * 2 * bins)
        powers = .allocate(capacity: 3 * bins)
        let channels = 2 * Splitter.partCount
        region = .allocate(capacity: channels * Self.regionLength)
        tail = .allocate(capacity: channels * Splitter.fade)
        scratch = .allocate(capacity: max(Self.regionLength, size))
        for buffer in [music, region, tail] {
            buffer.initialize(repeating: 0)
        }
        do {
            separating = try Run(network: .separating)
        } catch {
            NSLog("Liland: could not set up the HTDemucs buffers: \(error)")
            return nil
        }
    }

    deinit {
        if let forward { vDSP_DFT_DestroySetup(forward) }
        if let inverse { vDSP_DFT_DestroySetup(inverse) }
        [analysisWindow, synthesisWindow, crossfade, music, frame, evenSamples, oddSamples, real, imaginary,
         slices, powers, region, tail, scratch]
            .forEach { $0.deallocate() }
    }

    func run() {
        // HTDemucs loads up front; HTDemucs6s only once the guitar is chosen.
        if let model = Network.separating.loadedModel() {
            warmUp(separating, with: model)
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
            guard !state.hasFailed else { continue }

            if state.restart != lastRestart {
                lastRestart = state.restart
                start(at: state.restart)
            } else if state.written - consumed > Exchange.capacity / 2 {
                // Seconds behind (the Mac slept): the music left is too old to bother with.
                start(at: state.written)
            }
            take(upTo: state.written)
            while heard >= nextEnd {
                // After a GPU stall, skip windows that would come out late so the next one is on time.
                if heard - nextEnd > Self.lateness {
                    skip()
                } else {
                    separate(endingAt: nextEnd, keeping: Parts(rawValue: state.parts))
                }
                nextEnd += Splitter.hop
                let produced = produced
                exchange.state.withLock { $0.produced = produced }
            }
        }
    }

    /// The first prediction into new buffers is slow, so it's done before the music.
    private func warmUp(_ run: Run, with model: MLModel) {
        Network.predicting.withLock {
            _ = try? model.prediction(from: run.inputs, options: run.options)
        }
        run.model = model
    }

    private func start(at position: Int) {
        consumed = position
        produced = position
        heard = 0
        separating.transformedEnd = nil
        guitar?.transformedEnd = nil
        nextEnd = Splitter.ahead + Splitter.hop + Splitter.fade
        tail.update(repeating: 0)
        toNetwork?.reset()
        fromNetwork.forEach { $0.reset() }
        exchange.state.withLock {
            $0.origin = position
            $0.produced = position
        }
    }

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

    private func separate(endingAt end: Int, keeping parts: Parts) {
        let started = CFAbsoluteTimeGetCurrent()
        region.update(repeating: 0)

        // HTDemucs6s is heard from the next window on: its first run into new buffers is slow.
        var guitar: Run?
        if parts.contains(.guitar) {
            if let run = self.guitar {
                guitar = run
            } else if let model = Network.guitar.modelIfLoaded(), let run = try? Run(network: .guitar) {
                warmUp(run, with: model)
                self.guitar = run
            }
        }

        listen(separating, endingAt: end)
        var loudest: Float = 0
        vDSP_maxmgv(separating.wave.baseAddress!, 1, &loudest, vDSP_Length(separating.wave.count))
        guard !parts.isEmpty, loudest >= Self.silence else {
            separating.transformedEnd = nil
            self.guitar?.transformedEnd = nil
            write()
            return
        }

        guard predict(separating, endingAt: end) else {
            write()
            return
        }
        for (part, source) in Self.separatedSources.enumerated() {
            render(separating, source: source, into: part)
        }
        if let guitar {
            listen(guitar, endingAt: end)
            if predict(guitar, endingAt: end) {
                renderGuitar(from: guitar)
            }
        }
        write()

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        if timedRunCount < Self.timedRuns {
            timedRunCount += 1
            runTime += elapsed
            longestRun = max(longestRun, elapsed)
            if timedRunCount == Self.timedRuns {
                NSLog(
                    "Liland: separating takes %.0f ms on average (at most %.0f) for every %.0f ms of music",
                    runTime / Double(timedRunCount) * 1000, longestRun * 1000, Double(Splitter.hop) / Splitter.rate * 1000
                )
            }
        }
    }

    private func listen(_ run: Run, endingAt end: Int) {
        for channel in 0..<2 {
            for index in 0..<run.window {
                let position = end - run.window + index
                run.wave[channel * run.window + index] = position < 0
                    ? 0 : music[channel * Self.musicCapacity + (position & (Self.musicCapacity - 1))]
            }
        }
    }

    private func predict(_ run: Run, endingAt end: Int) -> Bool {
        transform(run, endingAt: end)
        run.spectrum.baseAddress!.update(from: run.rawSpectrum.baseAddress!, count: run.spectrum.count)
        (run.spectrumScale, run.spectrumShift) = Self.normalize(run.spectrum)
        (run.waveScale, run.waveShift) = Self.normalize(run.wave)
        do {
            Network.predicting.lock()
            defer { Network.predicting.unlock() }
            _ = try run.model?.prediction(from: run.inputs, options: run.options)
            return true
        } catch {
            NSLog("Liland: %@ failed: \(error)", run.network.name)
            return false
        }
    }

    private func render(_ run: Run, source: Int, into part: Int) {
        let length = Self.regionLength, bins = Splitter.bins, plane = bins * run.frames
        var scale = run.spectrumScale, shift = run.spectrumShift
        var waveScale = run.waveScale, waveShift = run.waveShift
        for channel in 0..<2 {
            let output = region.baseAddress! + (2 * part + channel) * length
            // Spectral branch, inverted frame by frame.
            for time in run.firstFrame...run.lastFrame {
                let realPlane = run.spectra.baseAddress! + (4 * source + 2 * channel) * plane + time
                vDSP_vsmsa(realPlane, vDSP_Stride(run.frames), &scale, &shift, real.baseAddress!, 1, vDSP_Length(bins))
                vDSP_vsmsa(realPlane + plane, vDSP_Stride(run.frames), &scale, &shift, imaginary.baseAddress!, 1, vDSP_Length(bins))
                // That slot holds the top frequency, which the network doesn't make.
                imaginary[0] = 0
                overlap(at: time * Splitter.fftHop - Self.frameOffset - run.regionStart, into: output)
            }
            // Plus the waveform branch.
            let wavePlane = run.waves.baseAddress! + (2 * source + channel) * run.window + run.regionStart
            vDSP_vsmsa(wavePlane, 1, &waveScale, &waveShift, scratch.baseAddress!, 1, vDSP_Length(length))
            vDSP_vadd(scratch.baseAddress!, 1, output, 1, output, 1, vDSP_Length(length))
        }
    }

    /// HTDemucs "other", masked per bin by 6s's guitar / (guitar + piano + rest) power.
    private func renderGuitar(from guitar: Run) {
        let bins = Splitter.bins, length = Self.regionLength
        // The same moment is this many frames further into the guitar network's longer window.
        let offset = guitar.frames - separating.frames
        let sources = Self.guitarSources
        for channel in 0..<2 {
            let output = region.baseAddress! + (2 * Self.guitarPart + channel) * length
            for time in separating.firstFrame...separating.lastFrame {
                slice(separating, source: Self.restSource, channel: channel, frame: time, into: 0)
                slice(guitar, source: sources.guitar, channel: channel, frame: time + offset, into: 1)
                slice(guitar, source: sources.piano, channel: channel, frame: time + offset, into: 2)
                slice(guitar, source: sources.rest, channel: channel, frame: time + offset, into: 3)
                for index in 0..<3 {
                    var spectrum = DSPSplitComplex(
                        realp: slices.baseAddress! + 2 * (index + 1) * bins,
                        imagp: slices.baseAddress! + (2 * (index + 1) + 1) * bins
                    )
                    vDSP_zvmags(&spectrum, 1, powers.baseAddress! + index * bins, 1, vDSP_Length(bins))
                }
                // The guitar's power share: rather nothing than a guess where all is silent.
                var tiny: Float = 1e-20
                vDSP_vadd(powers.baseAddress! + bins, 1, powers.baseAddress! + 2 * bins, 1, scratch.baseAddress!, 1, vDSP_Length(bins))
                vDSP_vadd(scratch.baseAddress!, 1, powers.baseAddress!, 1, scratch.baseAddress!, 1, vDSP_Length(bins))
                vDSP_vsadd(scratch.baseAddress!, 1, &tiny, scratch.baseAddress!, 1, vDSP_Length(bins))
                vDSP_vdiv(scratch.baseAddress!, 1, powers.baseAddress!, 1, scratch.baseAddress!, 1, vDSP_Length(bins))
                vDSP_vmul(slices.baseAddress!, 1, scratch.baseAddress!, 1, real.baseAddress!, 1, vDSP_Length(bins))
                vDSP_vmul(slices.baseAddress! + bins, 1, scratch.baseAddress!, 1, imaginary.baseAddress!, 1, vDSP_Length(bins))
                overlap(at: time * Splitter.fftHop - Self.frameOffset - separating.regionStart, into: output)
            }
        }
    }

    /// One source frame as a spectrum: its spectrogram plus its waveform branch, transformed.
    private func slice(_ run: Run, source: Int, channel: Int, frame time: Int, into index: Int) {
        guard let forward else { return }
        let bins = Splitter.bins, plane = bins * run.frames
        let sliceReal = slices.baseAddress! + 2 * index * bins, sliceImaginary = sliceReal + bins
        var scale = run.spectrumScale, shift = run.spectrumShift
        let realPlane = run.spectra.baseAddress! + (4 * source + 2 * channel) * plane + time
        vDSP_vsmsa(realPlane, vDSP_Stride(run.frames), &scale, &shift, sliceReal, 1, vDSP_Length(bins))
        vDSP_vsmsa(realPlane + plane, vDSP_Stride(run.frames), &scale, &shift, sliceImaginary, 1, vDSP_Length(bins))

        // The frame lies inside the window, so no mirroring past its edges.
        var waveScale = run.waveScale, waveShift = run.waveShift
        let samples = run.waves.baseAddress! + (2 * source + channel) * run.window + time * Splitter.fftHop - Self.frameOffset
        vDSP_vsmsa(samples, 1, &waveScale, &waveShift, frame.baseAddress!, 1, vDSP_Length(Splitter.fftSize))
        vDSP_vmul(frame.baseAddress!, 1, analysisWindow.baseAddress!, 1, frame.baseAddress!, 1, vDSP_Length(Splitter.fftSize))
        frame.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { pairs in
            var split = DSPSplitComplex(realp: evenSamples.baseAddress!, imagp: oddSamples.baseAddress!)
            vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(bins))
        }
        vDSP_DFT_Execute(forward, evenSamples.baseAddress!, oddSamples.baseAddress!, real.baseAddress!, imaginary.baseAddress!)
        var toSpectrogram = 1 / (2 * Float(Splitter.fftSize).squareRoot())
        vDSP_vsma(real.baseAddress!, 1, &toSpectrogram, sliceReal, 1, sliceReal, 1, vDSP_Length(bins))
        vDSP_vsma(imaginary.baseAddress!, 1, &toSpectrogram, sliceImaginary, 1, sliceImaginary, 1, vDSP_Length(bins))
        // That slot holds the top frequency, which HTDemucs drops.
        sliceImaginary[0] = 0
    }

    private func overlap(at offset: Int, into output: UnsafeMutablePointer<Float>) {
        guard let inverse else { return }
        vDSP_DFT_Execute(inverse, real.baseAddress!, imaginary.baseAddress!, evenSamples.baseAddress!, oddSamples.baseAddress!)
        frame.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Splitter.bins) { pairs in
            var split = DSPSplitComplex(realp: evenSamples.baseAddress!, imagp: oddSamples.baseAddress!)
            vDSP_ztoc(&split, 1, pairs, 2, vDSP_Length(Splitter.bins))
        }
        let from = max(0, -offset), to = min(Splitter.fftSize, Self.regionLength - offset)
        guard from < to else { return }
        let count = vDSP_Length(to - from)
        vDSP_vmul(frame.baseAddress! + from, 1, synthesisWindow.baseAddress! + from, 1, frame.baseAddress! + from, 1, count)
        vDSP_vadd(frame.baseAddress! + from, 1, output + offset + from, 1, output + offset + from, 1, count)
    }

    private func skip() {
        region.update(repeating: 0)
        separating.transformedEnd = nil
        guitar?.transformedEnd = nil
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

    private func write() {
        let capacity = Exchange.capacity, wrap = capacity - 1, length = Self.regionLength
        for channel in 0..<(2 * Splitter.partCount) {
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
        for part in 0..<Splitter.partCount {
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

    /// Planes per channel: real then imaginary, each bins × frames.
    private func transform(_ run: Run, endingAt end: Int) {
        guard let forward else { return }
        let window = run.window, frames = run.frames, size = Splitter.fftSize, bins = Splitter.bins
        let plane = bins * frames
        var scale = 1 / (2 * Float(size).squareRoot())
        // Inner frames shared with the previous window are shifted over, not recomputed.
        let lastInnerFrame = (window - size + Self.frameOffset) / Splitter.fftHop
        let reused = run.transformedEnd == end - Splitter.hop
            ? Self.firstInnerFrame..<(lastInnerFrame - Self.frameShift + 1) : 0..<0
        if !reused.isEmpty {
            for row in 0..<(4 * bins) {
                let first = run.rawSpectrum.baseAddress! + row * frames + reused.lowerBound
                first.update(from: first + Self.frameShift, count: reused.count)
            }
        }
        run.transformedEnd = end
        for channel in 0..<2 {
            let samples = run.wave.baseAddress! + channel * window
            for time in 0..<frames where !reused.contains(time) {
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
                let realPlane = run.rawSpectrum.baseAddress! + 2 * channel * plane + time
                vDSP_vsmul(real.baseAddress!, 1, &scale, realPlane, vDSP_Stride(frames), vDSP_Length(bins))
                vDSP_vsmul(imaginary.baseAddress!, 1, &scale, realPlane + plane, vDSP_Stride(frames), vDSP_Length(bins))
            }
        }
    }

    /// As HTDemucs does before the network; returns deviation and mean to undo it after.
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
