import Foundation
import Observation

@Observable
final class AudioLevelMonitor {
    private static let analysisLatency: TimeInterval = 0.04

    private(set) var live: LiveLevels?
    private(set) var permission = AudioCapturePermission.Status.unknown

    var isEnabled = Preferences.shouldEqualizerFollowMusic {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Preferences.equalizerFollowsMusic)
            update()
        }
    }

    var isAdvanced = Preferences.isAdvanced {
        didSet {
            UserDefaults.standard.set(isAdvanced, forKey: Preferences.advanced)
            update()
        }
    }

    var adjustments = Preferences.savedAudioAdjustments {
        didSet {
            guard adjustments != oldValue else { return }
            Preferences.savedAudioAdjustments = adjustments
            processor?.apply(adjustments)
        }
    }

    var isSupported: Bool {
        if #available(macOS 14.4, *) { true } else { false }
    }

    var isolatableParts: [AudioAdjustments.Part] {
        AudioAdjustments.Part.allCases.filter { $0 != .guitar || DemucsSplitter.canIsolateGuitar }
    }

    @ObservationIgnored private var bundleID: String?
    @ObservationIgnored private var isPlaying = false
    @ObservationIgnored private var tap: AnyObject?
    @ObservationIgnored private var processor: AudioProcessor?
    @ObservationIgnored private var adjustedSampleRate: Double?
    @ObservationIgnored private var starting: LiveLevels?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var hasRequested = false
    @ObservationIgnored private var isRequesting = false

    func follow(bundleID: String?, isPlaying: Bool) {
        self.bundleID = bundleID
        self.isPlaying = isPlaying
        update()
    }

    private func update() {
        guard isSupported, isEnabled || isAdvanced else {
            stop()
            return
        }
        let status = AudioCapturePermission.status
        if status != permission { permission = status }

        let needsTap = isPlaying || (isAdvanced && bundleID != nil)
        let needsTimer = needsTap || permission == .denied
        if needsTimer && timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.update() }
        } else if !needsTimer {
            timer?.invalidate()
            timer = nil
        }

        guard needsTap, let bundleID else {
            stopTap()
            return
        }

        switch permission {
        case .denied:
            stopTap()
        case .unknown where isRequesting:
            break
        case .unknown where !hasRequested:
            hasRequested = true
            isRequesting = true
            AudioCapturePermission.request { [weak self] _ in
                self?.isRequesting = false
                self?.update()
            }
        case .unknown, .authorized:
            startTap(for: bundleID)
        }
    }

    private func startTap(for bundleID: String) {
        guard #available(macOS 14.4, *) else { return }
        let processes = ProcessAudioTap.processes(of: bundleID)
        let outputUID = ProcessAudioTap.defaultOutputDeviceUID
        let sampleRate = isAdvanced ? ProcessAudioTap.defaultOutputSampleRate : nil

        if let current = tap as? ProcessAudioTap,
           current.processes == processes,
           current.outputDeviceUID == outputUID,
           current.isListening == isEnabled,
           adjustedSampleRate == sampleRate {
            return
        }
        stopTap()
        guard !processes.isEmpty, let outputUID else { return }

        adjustedSampleRate = sampleRate
        if let sampleRate {
            processor = AudioProcessor(sampleRate: sampleRate)
            processor?.apply(adjustments)
        }

        let outputLatency = ProcessAudioTap.defaultOutputLatency ?? 0
        NSLog(
            "Liland: %@ %@ on %@ (output latency %.0f ms)",
            processor == nil ? "listening to" : "adjusting", bundleID, outputUID, outputLatency * 1000
        )

        var handler: ProcessAudioTap.Handler?
        if isEnabled {
            let analyzer = SpectrumAnalyzer()
            let levels = LiveLevels(delay: max(0, outputLatency - Self.analysisLatency))
            var hasDelivered = false
            starting = levels
            handler = { [weak self] samples, channels, sampleRate in
                guard let result = analyzer.process(samples, channels: channels, sampleRate: sampleRate) else { return }
                levels.update(result)
                guard !hasDelivered else { return }
                hasDelivered = true
                DispatchQueue.main.async {
                    guard let self, self.starting === levels else { return }
                    self.live = levels
                }
            }
        }
        tap = ProcessAudioTap(processes: processes, outputDeviceUID: outputUID, processor: processor, handler: handler)
        if tap == nil { processor = nil }
    }

    private func stopTap() {
        tap = nil
        processor = nil
        adjustedSampleRate = nil
        starting = nil
        if live != nil { live = nil }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        stopTap()
    }
}
