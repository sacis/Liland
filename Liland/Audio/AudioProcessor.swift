import AVFoundation
import os

/// `render` runs on the audio thread and never waits for the main thread; `apply` runs on main.
final class AudioProcessor {
    private static let maximumFrames: AVAudioFrameCount = 4096
    private static let maximumMakeup: Float = 8 // +18 dB
    private static let loudnessWindow: Float = 3 // s
    private static let makeupTime: Float = 0.3 // s
    /// -30 dB: quieter stretches are pauses; raising the gain there would only bring up leakage.
    private static let pause: Float = 0.001
    private static let pauseWindow: Float = 0.4 // s, longer than the gaps between drum hits
    private static let pitchFlush = 2 * Int(maximumFrames) // samples; clears what the pitch stage held

    private struct Settings: Equatable {
        var parts: StemSplitter.Parts = []
        var isPitched = false
    }

    private let sampleRate: Float
    private let equalizer = AVAudioUnitEQ(numberOfBands: AudioAdjustments.bands.count)
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    ))
    private let timePitch = AVAudioUnitTimePitch()
    private let tone: RenderStage
    /// Delays ~85 ms even when bypassed, so it's a separate stage that only runs while pitched.
    private let pitch: RenderStage
    private let splitter: PartSplitter
    private let settings = OSAllocatedUnfairLock(initialState: Settings())

    // Only touched on the audio thread.
    private var rendered = Settings()
    private var songMeter: LoudnessMeter
    private var partsMeter: LoudnessMeter
    private var songPower: Float = 0
    private var partsPower: Float = 0
    private var recentSongPower: Float = 0
    private var recentPartsPower: Float = 0
    private var makeup: Float = 1
    /// Samples: the splitter's delay plus a part's fade-in (the bass waits to be sure the song has one).
    private var warmup = 0

    init?(sampleRate: Double) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return nil }
        self.sampleRate = Float(sampleRate)

        for (index, band) in equalizer.bands.enumerated() {
            band.frequency = AudioAdjustments.bands[index].frequency
            band.filterType = index == 0 ? .lowShelf : index == AudioAdjustments.bands.count - 1 ? .highShelf : .parametric
            band.bandwidth = 1.5
            band.gain = 0
            band.bypass = false
        }
        limiter.bypass = true

        guard let tone = RenderStage(format: format, maximumFrames: Self.maximumFrames, effects: [equalizer, limiter]),
              let pitch = RenderStage(format: format, maximumFrames: Self.maximumFrames, effects: [timePitch])
        else { return nil }
        self.tone = tone
        self.pitch = pitch
        splitter = (DemucsSplitter.isSupported ? DemucsSplitter(sampleRate: sampleRate) : nil)
            ?? StemSplitter(sampleRate: sampleRate)
        songMeter = LoudnessMeter(sampleRate: sampleRate)
        partsMeter = LoudnessMeter(sampleRate: sampleRate)
    }

    func apply(_ adjustments: AudioAdjustments) {
        var parts = StemSplitter.Parts()
        if adjustments.isolated.contains(.vocals) { parts.insert(.vocals) }
        if adjustments.isolated.contains(.guitar) { parts.insert(.guitar) }
        if adjustments.isolated.contains(.bass) { parts.insert(.bass) }
        if adjustments.isolated.contains(.drums) { parts.insert(.drums) }

        for band in AudioAdjustments.bands.indices {
            equalizer.bands[band].gain = adjustments.gain(band)
        }
        // Leave room for boosted bands so they don't clip.
        let boost = max(0, adjustments.gains.max() ?? 0)
        equalizer.globalGain = -boost / 2
        limiter.bypass = parts.isEmpty && boost == 0

        timePitch.pitch = Float(adjustments.pitch * 100)
        let latest = Settings(parts: parts, isPitched: adjustments.pitch != 0)
        settings.withLock { $0 = latest }
    }

    /// Runs on the audio thread; `source` is interleaved.
    func render(_ source: AudioBuffer, into destination: UnsafeMutableAudioBufferListPointer) {
        guard let samples = source.mData?.assumingMemoryBound(to: Float.self) else { return }
        let sourceChannels = max(Int(source.mNumberChannels), 1)
        let frames = Int(source.mDataByteSize) / MemoryLayout<Float>.size / sourceChannels

        if let latest = settings.withLockIfAvailable({ $0 }), latest != rendered {
            update(to: latest)
        }

        var done = 0
        while done < frames {
            let count = min(frames - done, Int(Self.maximumFrames))
            let left = tone.left, right = tone.right
            for frame in 0..<count {
                let base = (done + frame) * sourceChannels
                left[frame] = samples[base]
                right[frame] = samples[base + min(1, sourceChannels - 1)]
            }
            if !rendered.parts.isEmpty {
                isolate(left: left, right: right, frames: count)
            }

            // If an engine fails, play the music as it came into it rather than nothing.
            var adjusted = tone.render(frames: count) ? tone.output : tone.input
            if rendered.isPitched {
                pitch.left.update(from: adjusted[0].mData!.assumingMemoryBound(to: Float.self), count: count)
                pitch.right.update(from: adjusted[1].mData!.assumingMemoryBound(to: Float.self), count: count)
                if pitch.render(frames: count) { adjusted = pitch.output }
            }
            write(
                left: adjusted[0].mData!.assumingMemoryBound(to: Float.self),
                right: adjusted[1].mData!.assumingMemoryBound(to: Float.self),
                frames: count,
                at: done,
                into: destination
            )
            done += count
        }
    }

    private func update(to latest: Settings) {
        if latest.parts != rendered.parts {
            if rendered.parts.isEmpty {
                splitter.reset()
                makeup = 1
            }
            songPower = 0
            partsPower = 0
            recentSongPower = 0
            recentPartsPower = 0
            warmup = splitter.latency + Int(sampleRate / 2)
        }
        if latest.isPitched && !rendered.isPitched {
            pitch.left.update(repeating: 0, count: Int(Self.maximumFrames))
            pitch.right.update(repeating: 0, count: Int(Self.maximumFrames))
            for _ in 0..<(Self.pitchFlush / Int(Self.maximumFrames)) {
                _ = pitch.render(frames: Int(Self.maximumFrames))
            }
        }
        rendered = latest
    }

    /// Raises the kept parts toward the song's perceived loudness, so dropping parts doesn't quiet it.
    private func isolate(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let song = songMeter.power(left: left, right: right, frames: frames)
        splitter.process(left: left, right: right, frames: frames, keeping: rendered.parts)
        let parts = partsMeter.power(left: left, right: right, frames: frames)

        let duration = Float(frames) / sampleRate
        let recent = 1 - exp(-duration / Self.pauseWindow)
        recentSongPower += (song - recentSongPower) * recent
        recentPartsPower += (parts - recentPartsPower) * recent
        if warmup <= 0 && recentPartsPower > recentSongPower * Self.pause {
            let smoothing = 1 - exp(-duration / Self.loudnessWindow)
            songPower += (song - songPower) * smoothing
            partsPower += (parts - partsPower) * smoothing
        }

        var target = makeup
        if warmup > 0 {
            warmup -= frames
        } else if songPower > 1e-12 {
            target = min(max((songPower / max(partsPower, 1e-12)).squareRoot(), 1), Self.maximumMakeup)
        }
        let next = makeup + (target - makeup) * (1 - exp(-Float(frames) / (sampleRate * Self.makeupTime)))
        // Glide from the old gain to the new one across the block, so it never clicks.
        let step = (next - makeup) / Float(frames)
        for frame in 0..<frames {
            let gain = makeup + step * Float(frame + 1)
            left[frame] *= gain
            right[frame] *= gain
        }
        makeup = next
    }

    private func write(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frames: Int,
        at offset: Int,
        into destination: UnsafeMutableAudioBufferListPointer
    ) {
        guard let buffer = destination.first, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
        let channels = Int(buffer.mNumberChannels)
        guard channels > 0 else { return }
        let capacity = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
        for frame in 0..<min(frames, capacity - offset) {
            let base = (offset + frame) * channels
            if channels == 1 {
                data[base] = (left[frame] + right[frame]) / 2
            } else {
                data[base] = left[frame]
                data[base + 1] = right[frame]
            }
        }
    }
}

protocol PartSplitter: AnyObject {
    var latency: Int { get } // samples
    func reset()
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, keeping parts: StemSplitter.Parts)
}

extension DemucsSplitter: PartSplitter {}

extension StemSplitter: PartSplitter {
    var latency: Int { Self.latency }
}

private final class RenderStage {
    let inputBuffer: AVAudioPCMBuffer
    let outputBuffer: AVAudioPCMBuffer
    let input: UnsafeMutableAudioBufferListPointer
    let output: UnsafeMutableAudioBufferListPointer

    private let engine = AVAudioEngine()
    private let renderBlock: AVAudioEngineManualRenderingBlock

    var left: UnsafeMutablePointer<Float> { input[0].mData!.assumingMemoryBound(to: Float.self) }
    var right: UnsafeMutablePointer<Float> { input[1].mData!.assumingMemoryBound(to: Float.self) }

    init?(format: AVAudioFormat, maximumFrames: AVAudioFrameCount, effects: [AVAudioNode]) {
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrames),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrames)
        else { return nil }
        inputBuffer.frameLength = maximumFrames
        outputBuffer.frameLength = maximumFrames
        self.inputBuffer = inputBuffer
        self.outputBuffer = outputBuffer
        input = UnsafeMutableAudioBufferListPointer(inputBuffer.mutableAudioBufferList)
        output = UnsafeMutableAudioBufferListPointer(outputBuffer.mutableAudioBufferList)

        do {
            try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: maximumFrames)
        } catch {
            NSLog("Liland: could not set up the sound adjustments: \(error)")
            return nil
        }
        // The engine pulls the input while rendering, on the same thread, after it was filled.
        let pending = UnsafePointer(inputBuffer.mutableAudioBufferList)
        guard engine.inputNode.setManualRenderingInputPCMFormat(format, inputBlock: { _ in pending }) else { return nil }

        var previous: AVAudioNode = engine.inputNode
        for effect in effects {
            engine.attach(effect)
            engine.connect(previous, to: effect, format: format)
            previous = effect
        }
        engine.connect(previous, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            NSLog("Liland: could not start the sound adjustments: \(error)")
            return nil
        }
        renderBlock = engine.manualRenderingBlock
    }

    deinit {
        engine.stop()
    }

    func render(frames: Int) -> Bool {
        let byteSize = UInt32(frames * MemoryLayout<Float>.size)
        for index in 0..<2 {
            input[index].mDataByteSize = byteSize
            output[index].mDataByteSize = byteSize
        }
        var status = OSStatus(noErr)
        return renderBlock(AVAudioFrameCount(frames), outputBuffer.mutableAudioBufferList, &status) == .success
    }
}

/// ITU BS.1770 loudness: high-pass ~38 Hz and +4 dB above ~1.5 kHz, then mean power of both channels.
private struct LoudnessMeter {
    private var leftShelf: Biquad, rightShelf: Biquad
    private var leftHighPass: Biquad, rightHighPass: Biquad

    init(sampleRate: Double) {
        leftShelf = .highShelf(1_500, gain: 4, sampleRate: sampleRate)
        rightShelf = leftShelf
        leftHighPass = .highPass(38, q: 0.5, sampleRate: sampleRate)
        rightHighPass = leftHighPass
    }

    mutating func power(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) -> Float {
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        for frame in 0..<frames {
            let l = leftHighPass.process(leftShelf.process(left[frame]))
            let r = rightHighPass.process(rightShelf.process(right[frame]))
            sum += l * l + r * r
        }
        return sum / Float(frames)
    }
}
