import AVFoundation
import os

/// One deck in DJ mode: keeps some of its parts, then stretches it so its beat follows the other deck's and
/// moves its key. `render` runs on the audio thread; everything else on main.
final class DeckProcessor {
    typealias Parts = StemSplitter.Parts

    static let maximumFrames = 4096
    /// Equal-power crossfade when the kept parts change: about half a beat.
    private static let partFade = 0.25 // s
    private static let fade = 0.01 // s, around inserted silence and jumps

    /// Positions in the samples this deck received, read together with the other deck's.
    struct Timing {
        /// The music now going into the stretch (what plays next), as a position in what was received.
        var playing = 0
        var backlog = 0 // samples waiting to be stretched
        var isAdjusting = false // a silence or jump is under way
    }

    enum Adjustment {
        case delay(Int) // play silence, holding the music back
        case skip(Int) // drop music that's waiting
        case flush // drop everything waiting
    }

    let analyzer: BeatAnalyzer
    let sampleRate: Double

    private let splitter: DemucsSplitter
    private let stretch: StretchStage
    private let fifo: StereoFifo
    private let left: UnsafeMutableBufferPointer<Float>
    private let right: UnsafeMutableBufferPointer<Float>
    let outputLeft: UnsafeMutableBufferPointer<Float>
    let outputRight: UnsafeMutableBufferPointer<Float>

    private struct Settings {
        var parts: Parts = .everything
        var gain: Float = 1
    }

    private let settings = OSAllocatedUnfairLock(initialState: Settings())
    private let adjustments = OSAllocatedUnfairLock<[Adjustment]>(initialState: [])

    /// As of the last `render`; read it on the audio thread (`DJAudioEngine` hands it over).
    private(set) var timing = Timing()

    // Only touched on the audio thread.
    private var parts: Parts = .everything
    private var gain: Float = 0
    private var targetGain: Float = 1
    private var silence = 0
    private var fadeIn = 0

    init?(sampleRate: Double) {
        guard let splitter = DemucsSplitter(sampleRate: sampleRate),
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        else { return nil }
        self.sampleRate = sampleRate
        self.splitter = splitter
        splitter.partFade = Int(Self.partFade * sampleRate)
        analyzer = BeatAnalyzer(sampleRate: sampleRate)
        // ~45 s at 48 kHz: room for a slowed song's lag to build up.
        fifo = StereoFifo(capacity: 1 << 21)
        guard let stretch = StretchStage(format: format, maximumFrames: Self.maximumFrames, fifo: fifo) else { return nil }
        self.stretch = stretch
        left = .allocate(capacity: Self.maximumFrames)
        right = .allocate(capacity: Self.maximumFrames)
        outputLeft = .allocate(capacity: Self.maximumFrames)
        outputRight = .allocate(capacity: Self.maximumFrames)
        for buffer in [left, right, outputLeft, outputRight] {
            buffer.initialize(repeating: 0)
        }
    }

    deinit {
        [left, right, outputLeft, outputRight].forEach { $0.deallocate() }
    }

    // MARK: - Main thread

    func set(parts: Parts, gain: Float) {
        settings.withLock { $0 = Settings(parts: parts, gain: gain) }
    }

    /// Below 1 slows the music down (it then falls behind what's received); pitch in semitones.
    func set(rate: Double, pitch: Double) {
        stretch.unit.rate = Float(rate)
        stretch.unit.pitch = Float(pitch * 100)
    }

    func adjust(_ adjustment: Adjustment) {
        adjustments.withLock { $0.append(adjustment) }
    }

    // MARK: - Audio thread

    /// Fills `outputLeft` and `outputRight` with `frames` samples.
    func render(_ source: AudioBuffer, frames: Int) {
        guard let samples = source.mData?.assumingMemoryBound(to: Float.self) else { return }
        let channels = max(Int(source.mNumberChannels), 1)
        let frames = min(frames, Self.maximumFrames)

        if let latest = settings.withLockIfAvailable({ $0 }) {
            parts = latest.parts
            targetGain = latest.gain
        }
        if let pending = adjustments.withLockIfAvailable({ list -> [Adjustment] in
            defer { list.removeAll(keepingCapacity: true) }
            return list
        }) {
            for adjustment in pending { apply(adjustment) }
        }

        for frame in 0..<frames {
            left[frame] = samples[frame * channels]
            right[frame] = samples[frame * channels + min(1, channels - 1)]
        }
        analyzer.feed(left: left.baseAddress!, right: right.baseAddress!, frames: frames)
        splitter.process(left: left.baseAddress!, right: right.baseAddress!, frames: frames, keeping: parts)
        fifo.write(left: left.baseAddress!, right: right.baseAddress!, count: frames)

        // Silence first, if the beat asked for it, then the stretched music.
        let quiet = min(silence, frames)
        for frame in 0..<quiet {
            outputLeft[frame] = 0
            outputRight[frame] = 0
        }
        silence -= quiet
        if quiet < frames {
            let count = frames - quiet
            if stretch.render(frames: count) {
                outputLeft.baseAddress!.advanced(by: quiet).update(from: stretch.left, count: count)
                outputRight.baseAddress!.advanced(by: quiet).update(from: stretch.right, count: count)
            } else {
                for frame in quiet..<frames {
                    outputLeft[frame] = 0
                    outputRight[frame] = 0
                }
            }
        }

        // Glide to the new volume across the block; fade back in after a silence or a jump.
        let fadeLength = Int(Self.fade * sampleRate)
        let step = (targetGain - gain) / Float(frames)
        for frame in 0..<frames {
            gain += step
            var level = gain
            if frame >= quiet && fadeIn > 0 {
                level *= 1 - Float(fadeIn) / Float(fadeLength)
                fadeIn -= 1
            }
            outputLeft[frame] *= level
            outputRight[frame] *= level
        }

        timing = Timing(playing: fifo.readIndex - splitter.latency, backlog: fifo.available, isAdjusting: silence > 0)
    }

    private func apply(_ adjustment: Adjustment) {
        let fadeLength = Int(Self.fade * sampleRate)
        switch adjustment {
        case .delay(let samples):
            silence += max(0, samples)
        case .skip(let samples):
            fifo.skip(min(max(0, samples), fifo.available))
        case .flush:
            fifo.skip(fifo.available)
            silence = 0
        }
        fadeIn = fadeLength
    }
}

/// Holds music from the splitter until the stretch takes it. Written and read on the same thread.
private final class StereoFifo {
    let capacity: Int
    private let left: UnsafeMutableBufferPointer<Float>
    private let right: UnsafeMutableBufferPointer<Float>
    private(set) var writeIndex = 0
    private(set) var readIndex = 0

    init(capacity: Int) {
        self.capacity = capacity
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0)
        right.initialize(repeating: 0)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    var available: Int { writeIndex - readIndex }

    func write(left source: UnsafePointer<Float>, right sourceRight: UnsafePointer<Float>, count: Int) {
        let wrap = capacity - 1
        for index in 0..<count {
            left[(writeIndex + index) & wrap] = source[index]
            right[(writeIndex + index) & wrap] = sourceRight[index]
        }
        writeIndex += count
        // Never more behind than it can hold: the oldest goes.
        if available > capacity { readIndex = writeIndex - capacity }
    }

    /// Reads up to `count`, zero-filling the rest; returns how many were music.
    @discardableResult
    func read(into destination: UnsafeMutablePointer<Float>, _ destinationRight: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let wrap = capacity - 1
        let taken = min(count, available)
        for index in 0..<taken {
            destination[index] = left[(readIndex + index) & wrap]
            destinationRight[index] = right[(readIndex + index) & wrap]
        }
        for index in taken..<count {
            destination[index] = 0
            destinationRight[index] = 0
        }
        readIndex += taken
        return taken
    }

    func skip(_ count: Int) {
        readIndex += min(count, available)
    }
}

/// AVAudioUnitTimePitch in a manually rendered engine, pulling its music from the FIFO as fast as `rate` needs.
private final class StretchStage {
    let unit = AVAudioUnitTimePitch()
    private let engine = AVAudioEngine()
    private let fifo: StereoFifo
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private let inputList: UnsafeMutableAudioBufferListPointer
    private let outputList: UnsafeMutableAudioBufferListPointer
    private var renderBlock: AVAudioEngineManualRenderingBlock!

    var left: UnsafePointer<Float> { UnsafePointer(outputList[0].mData!.assumingMemoryBound(to: Float.self)) }
    var right: UnsafePointer<Float> { UnsafePointer(outputList[1].mData!.assumingMemoryBound(to: Float.self)) }

    init?(format: AVAudioFormat, maximumFrames: Int, fifo: StereoFifo) {
        self.fifo = fifo
        // The unit may ask for more than one block's worth when it runs fast.
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maximumFrames * 8)),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maximumFrames))
        else { return nil }
        input.frameLength = input.frameCapacity
        output.frameLength = output.frameCapacity
        self.input = input
        self.output = output
        inputList = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        outputList = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)

        do {
            try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: AVAudioFrameCount(maximumFrames))
        } catch {
            NSLog("Liland: could not set up the DJ stretch: \(error)")
            return nil
        }
        let capacity = Int(input.frameCapacity)
        let list = UnsafePointer(input.mutableAudioBufferList)
        let pull: AVAudioIONodeInputBlock = { [unowned self] requested in
            let count = min(Int(requested), capacity)
            let byteSize = UInt32(count * MemoryLayout<Float>.size)
            self.inputList[0].mDataByteSize = byteSize
            self.inputList[1].mDataByteSize = byteSize
            self.fifo.read(
                into: self.inputList[0].mData!.assumingMemoryBound(to: Float.self),
                self.inputList[1].mData!.assumingMemoryBound(to: Float.self),
                count: count
            )
            return list
        }
        guard engine.inputNode.setManualRenderingInputPCMFormat(format, inputBlock: pull) else { return nil }
        unit.overlap = 16 // the cleanest it gets: two songs at once hide no artifacts
        engine.attach(unit)
        engine.connect(engine.inputNode, to: unit, format: format)
        engine.connect(unit, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            NSLog("Liland: could not start the DJ stretch: \(error)")
            return nil
        }
        renderBlock = engine.manualRenderingBlock
    }

    deinit {
        engine.stop()
    }

    func render(frames: Int) -> Bool {
        let byteSize = UInt32(frames * MemoryLayout<Float>.size)
        outputList[0].mDataByteSize = byteSize
        outputList[1].mDataByteSize = byteSize
        var status = OSStatus(noErr)
        return renderBlock(AVAudioFrameCount(frames), output.mutableAudioBufferList, &status) == .success
    }
}
