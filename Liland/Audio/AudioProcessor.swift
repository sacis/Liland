import AVFoundation
import os

/// Reshapes the music before it reaches the speakers: keeps one part of it, equalizes
/// it and moves it up or down in pitch.
///
/// `render` runs on the audio thread and never waits for the main thread; `apply` runs
/// on the main thread. Isolation runs first (`HarmonicPercussiveSplitter`, plus a filter
/// for the range of the part), then the equalizer, then the pitch.
final class AudioProcessor {
    private static let maximumFrames: AVAudioFrameCount = 4096
    /// Two high-pass and two low-pass filters that frame the isolated part, before the user's bands.
    private static let isolationBands = 4

    private let engine = AVAudioEngine()
    private let equalizer = AVAudioUnitEQ(numberOfBands: AudioProcessor.isolationBands + AudioAdjustments.bands.count)
    private let timePitch = AVAudioUnitTimePitch()
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private let inputList: UnsafeMutableAudioBufferListPointer
    private let outputList: UnsafeMutableAudioBufferListPointer
    private let renderBlock: AVAudioEngineManualRenderingBlock

    private let splitter = HarmonicPercussiveSplitter()
    private let isolation = OSAllocatedUnfairLock(initialState: AudioAdjustments.Isolation.none)
    /// What the audio thread is applying; only touched there.
    private var renderedIsolation = AudioAdjustments.Isolation.none

    init?(sampleRate: Double) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.maximumFrames),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.maximumFrames)
        else { return nil }
        // Full length once; each render then sets how much of it is used.
        input.frameLength = Self.maximumFrames
        output.frameLength = Self.maximumFrames
        self.input = input
        self.output = output
        inputList = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        outputList = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)

        do {
            try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: Self.maximumFrames)
        } catch {
            NSLog("Liland: could not set up the sound adjustments: \(error)")
            return nil
        }
        // The engine pulls the input while rendering, on the same thread, after `render` filled it.
        let pending = UnsafePointer(input.mutableAudioBufferList)
        guard engine.inputNode.setManualRenderingInputPCMFormat(format, inputBlock: { _ in pending }) else { return nil }

        for (index, band) in equalizer.bands.enumerated() {
            band.bypass = true
            if index >= Self.isolationBands {
                let user = index - Self.isolationBands
                band.frequency = AudioAdjustments.bands[user].frequency
                band.filterType = user == 0 ? .lowShelf : user == AudioAdjustments.bands.count - 1 ? .highShelf : .parametric
                band.bandwidth = 1.5
                band.gain = 0
                band.bypass = false
            } else {
                band.filterType = index < 2 ? .highPass : .lowPass
            }
        }
        timePitch.bypass = true

        engine.attach(equalizer)
        engine.attach(timePitch)
        engine.connect(engine.inputNode, to: equalizer, format: format)
        engine.connect(equalizer, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
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

    func apply(_ adjustments: AudioAdjustments) {
        isolation.withLock { $0 = adjustments.isolation }

        // The range each part lives in: (high-pass, low-pass) in Hz, nil for no filter.
        let range: (low: Float?, high: Float?) = switch adjustments.isolation {
        case .none, .drums: (nil, nil)
        case .vocals: (150, 7_000)
        case .bass: (nil, 220)
        }
        for index in 0..<Self.isolationBands {
            let band = equalizer.bands[index]
            let cutoff = index < 2 ? range.low : range.high
            if let cutoff { band.frequency = cutoff }
            // The low-pass for vocals is gentle; everything else is doubled to cut steeper.
            band.bypass = cutoff == nil || (adjustments.isolation == .vocals && index == 3)
        }

        for band in AudioAdjustments.bands.indices {
            equalizer.bands[Self.isolationBands + band].gain = adjustments.gain(band)
        }
        // Leave room for boosted bands so they don't clip.
        equalizer.globalGain = -max(0, adjustments.gains.max() ?? 0) / 2

        timePitch.pitch = Float(adjustments.pitch * 100)
        timePitch.bypass = adjustments.pitch == 0
    }

    /// Reads the tapped music (interleaved) and writes the adjusted music to the device's output buffers.
    /// Runs on the audio thread.
    func render(_ source: AudioBuffer, into destination: UnsafeMutableAudioBufferListPointer) {
        guard let samples = source.mData?.assumingMemoryBound(to: Float.self) else { return }
        let sourceChannels = max(Int(source.mNumberChannels), 1)
        let frames = Int(source.mDataByteSize) / MemoryLayout<Float>.size / sourceChannels

        if let latest = isolation.withLockIfAvailable({ $0 }), latest != renderedIsolation {
            renderedIsolation = latest
            splitter.reset()
        }

        var done = 0
        while done < frames {
            let count = min(frames - done, Int(Self.maximumFrames))
            let left = inputList[0].mData!.assumingMemoryBound(to: Float.self)
            let right = inputList[1].mData!.assumingMemoryBound(to: Float.self)
            for frame in 0..<count {
                let base = (done + frame) * sourceChannels
                left[frame] = samples[base]
                right[frame] = samples[base + min(1, sourceChannels - 1)]
            }
            isolate(left: left, right: right, frames: count)

            let byteSize = UInt32(count * MemoryLayout<Float>.size)
            for index in 0..<2 {
                inputList[index].mDataByteSize = byteSize
                outputList[index].mDataByteSize = byteSize
            }
            var status = OSStatus(noErr)
            let result = renderBlock(AVAudioFrameCount(count), output.mutableAudioBufferList, &status)
            // If the engine fails, play the music as it came rather than nothing.
            let adjusted = result == .success ? outputList : inputList
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

    private func isolate(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        switch renderedIsolation {
        case .none:
            return
        case .vocals, .bass:
            // Lead vocals and bass sit in the center: keep what both channels share.
            for frame in 0..<frames {
                let center = (left[frame] + right[frame]) / 2
                left[frame] = center
                right[frame] = center
            }
            splitter.process(left: left, right: right, frames: frames, keeping: .harmonic)
        case .drums:
            splitter.process(left: left, right: right, frames: frames, keeping: .percussive)
        }
    }

    /// Fills the first two channels of the first output stream (or its only one, mixed down).
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
