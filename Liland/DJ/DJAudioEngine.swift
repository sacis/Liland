import AudioToolbox
import CoreAudio
import os

/// Mutes each deck's Spotify and plays the mix instead: one private aggregate device with one tap per deck,
/// so both decks are read and mixed in the same cycle. Releasing it lets the apps be heard again.
@available(macOS 14.4, *)
final class DJAudioEngine {
    let decks: [DeckProcessor]
    let sampleRate: Double
    let outputDeviceUID: String

    private var taps: [AudioObjectID] = []
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "Liland.DJAudioEngine", qos: .userInteractive)
    private let timings: OSAllocatedUnfairLock<[DeckProcessor.Timing]>

    // Only touched on the audio thread.
    private var limiterGain: Float = 1
    private var hasLoggedLayout = false

    private static let ceiling: Float = 0.94 // −0.5 dBFS
    private static let release: Float = 0.15 // s

    /// `processes[i]` feeds `decks[i]`.
    init?(processes: [AudioObjectID], decks: [DeckProcessor], outputDeviceUID: String) {
        guard processes.count == decks.count, !decks.isEmpty else { return nil }
        self.decks = decks
        self.outputDeviceUID = outputDeviceUID
        sampleRate = decks[0].sampleRate
        timings = OSAllocatedUnfairLock(initialState: decks.map { _ in DeckProcessor.Timing() })

        var tapList: [[String: Any]] = []
        for process in processes {
            let description = CATapDescription(stereoMixdownOfProcesses: [process])
            description.uuid = UUID()
            description.isPrivate = true
            // Muted only while Liland reads the tap, so the music comes back if Liland stops or quits.
            description.muteBehavior = .mutedWhenTapped
            var tap = AudioObjectID(kAudioObjectUnknown)
            guard AudioHardwareCreateProcessTap(description, &tap) == noErr else {
                DJController.log.error("could not create a DJ audio tap")
                stop()
                return nil
            }
            taps.append(tap)
            tapList.append([kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString])

            var format = AudioStreamBasicDescription()
            guard tap.read(kAudioTapPropertyFormat, into: &format),
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32
            else {
                DJController.log.error("unexpected DJ tap format")
                stop()
                return nil
            }
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Liland DJ",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: tapList,
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else {
            DJController.log.error("could not create the DJ aggregate device")
            stop()
            return nil
        }

        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [unowned self] _, input, _, output, _ in
            self.render(input: input, output: output)
        }
        guard status == noErr, AudioDeviceStart(aggregateID, ioProcID) == noErr else {
            DJController.log.error("could not start the DJ audio")
            stop()
            return nil
        }
    }

    deinit {
        stop()
    }

    /// Each deck's positions, all from the same audio cycle.
    var deckTimings: [DeckProcessor.Timing] {
        timings.withLock { $0 }
    }

    private func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                self.ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        for tap in taps {
            AudioHardwareDestroyProcessTap(tap)
        }
        taps = []
    }

    // MARK: - Audio thread

    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        guard let destination = outputs.first, let data = destination.mData?.assumingMemoryBound(to: Float.self) else { return }
        let outputChannels = max(Int(destination.mNumberChannels), 1)
        let outputFrames = Int(destination.mDataByteSize) / MemoryLayout<Float>.size / outputChannels

        // The taps come after any input the output device itself has (a headset's microphone).
        let first = inputs.count - decks.count
        if !hasLoggedLayout {
            hasLoggedLayout = true
            let (buffers, count) = (inputs.count, decks.count)
            DJController.log.notice("audio has \(buffers, privacy: .public) input buffers for \(count, privacy: .public) decks, \(outputFrames, privacy: .public) frames")
        }
        guard first >= 0 else {
            data.update(repeating: 0, count: outputFrames * outputChannels)
            return
        }

        var frames = outputFrames
        for index in decks.indices {
            let buffer = inputs[first + index]
            let channels = max(Int(buffer.mNumberChannels), 1)
            frames = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels)
        }
        frames = min(frames, DeckProcessor.maximumFrames)
        for (index, deck) in decks.enumerated() {
            deck.render(inputs[first + index], frames: frames)
        }

        // A peak limiter: instant attack, smooth release, so two loud songs don't clip.
        let release = 1 - exp(-1 / (Self.release * Float(sampleRate)))
        for frame in 0..<outputFrames {
            var left: Float = 0, right: Float = 0
            if frame < frames {
                for deck in decks {
                    left += deck.outputLeft[frame]
                    right += deck.outputRight[frame]
                }
            }
            let peak = max(abs(left), abs(right)) * limiterGain
            if peak > Self.ceiling {
                limiterGain *= Self.ceiling / peak
            } else {
                limiterGain += (1 - limiterGain) * release
            }
            left *= limiterGain
            right *= limiterGain
            let base = frame * outputChannels
            if outputChannels == 1 {
                data[base] = (left + right) / 2
            } else {
                data[base] = left
                data[base + 1] = right
                for extra in 2..<max(outputChannels, 2) { data[base + extra] = 0 }
            }
        }

        timings.withLockIfAvailable { timings in
            for index in decks.indices { timings[index] = decks[index].timing }
        }
    }
}
