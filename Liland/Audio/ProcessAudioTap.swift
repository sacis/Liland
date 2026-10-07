import AudioToolbox
import CoreAudio

/// Listens to what some processes are playing, without changing what the user hears.
/// Exists while it runs: creating it starts the tap, releasing it stops everything.
@available(macOS 14.4, *)
final class ProcessAudioTap {
    /// Interleaved samples, the number of channels, and the sample rate. Called on a background queue.
    typealias Handler = (_ samples: UnsafeBufferPointer<Float>, _ channels: Int, _ sampleRate: Double) -> Void

    let processes: [AudioObjectID]
    let outputDeviceUID: String

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "Liland.ProcessAudioTap", qos: .userInitiated)

    init?(processes: [AudioObjectID], outputDeviceUID: String, handler: @escaping Handler) {
        self.processes = processes
        self.outputDeviceUID = outputDeviceUID

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else {
            NSLog("Liland: could not create the audio tap")
            return nil
        }

        var format = AudioStreamBasicDescription()
        guard tapID.read(kAudioTapPropertyFormat, into: &format),
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32
        else {
            NSLog("Liland: unexpected audio tap format")
            stop()
            return nil
        }
        let sampleRate = format.mSampleRate

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Liland",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else {
            NSLog("Liland: could not create the aggregate device")
            stop()
            return nil
        }

        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let buffer = buffers.first, let data = buffer.mData else { return }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
            handler(samples, max(Int(buffer.mNumberChannels), 1), sampleRate)
        }
        guard status == noErr, AudioDeviceStart(aggregateID, ioProcID) == noErr else {
            NSLog("Liland: could not start the audio tap")
            stop()
            return nil
        }
    }

    deinit {
        stop()
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
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Finding what to tap

    /// Audio process objects of an app and its helpers (bundle IDs that start with `bundleID`).
    static func processes(of bundleID: String) -> [AudioObjectID] {
        AudioObjectID.system.objects(kAudioHardwarePropertyProcessObjectList).filter { process in
            process.string(kAudioProcessPropertyBundleID)?.hasPrefix(bundleID) == true
        }
    }

    /// The device the user is listening on, which drives the tap's clock.
    static var defaultOutputDeviceUID: String? {
        defaultOutputDevice?.string(kAudioDevicePropertyDeviceUID)
    }

    /// How long sound takes from the tap to the user's ears on the current output,
    /// as the device reports it: a few milliseconds on speakers, much more on Bluetooth.
    static var defaultOutputLatency: TimeInterval? {
        guard let device = defaultOutputDevice else { return nil }
        let output = kAudioObjectPropertyScopeOutput
        var sampleRate: Float64 = 0
        guard device.read(kAudioDevicePropertyNominalSampleRate, into: &sampleRate), sampleRate > 0 else { return nil }

        var frames: UInt32 = 0
        for selector in [kAudioDevicePropertyLatency, kAudioDevicePropertySafetyOffset, kAudioDevicePropertyBufferFrameSize] {
            var value: UInt32 = 0
            if device.read(selector, scope: output, into: &value) { frames += value }
        }
        let streamLatency = device.objects(kAudioDevicePropertyStreams, scope: output).map { stream -> UInt32 in
            var value: UInt32 = 0
            return stream.read(kAudioStreamPropertyLatency, into: &value) ? value : 0
        }.max() ?? 0
        return Double(frames + streamLatency) / sampleRate
    }

    private static var defaultOutputDevice: AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        guard AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, into: &device),
              device != kAudioObjectUnknown
        else { return nil }
        return device
    }
}

private extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func read<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        into value: inout T
    ) -> Bool {
        var address = Self.address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0) == noErr
        }
    }

    func string(_ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    func objects(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var address = Self.address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
}
