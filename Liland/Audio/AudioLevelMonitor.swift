import Foundation
import Observation

/// Listens to the active player so the equalizer can move with the music, and in
/// Advanced mode plays the player's sound through the user's adjustments.
///
/// `live` is nil whenever live audio isn't available (option off, permission denied,
/// macOS older than 14.4, nothing playing), and the equalizer keeps its own animation.
@Observable
final class AudioLevelMonitor {
    /// About how late the tap already is: one Core Audio buffer plus half the analysis window.
    private static let analysisLatency: TimeInterval = 0.02

    /// Set once the tap delivers its first levels.
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

    @ObservationIgnored private var bundleID: String?
    @ObservationIgnored private var isPlaying = false
    @ObservationIgnored private var tap: AnyObject?
    @ObservationIgnored private var processor: AudioProcessor?
    /// The output rate the running tap was made to adjust at, nil when it only listens.
    @ObservationIgnored private var adjustedSampleRate: Double?
    /// The levels of the running tap, before it has delivered anything.
    @ObservationIgnored private var starting: LiveLevels?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var hasRequested = false
    @ObservationIgnored private var isRequesting = false

    func follow(bundleID: String?, isPlaying: Bool) {
        self.bundleID = bundleID
        self.isPlaying = isPlaying
        update()
    }

    /// Re-run every second while it matters, to notice the permission being granted
    /// in Settings, the player restarting, or a new output device (like headphones).
    private func update() {
        guard isSupported, isEnabled || isAdvanced else {
            stop()
            return
        }
        let status = AudioCapturePermission.status
        if status != permission { permission = status }

        // Adjusting keeps going while paused, so the music comes back already adjusted.
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
        // A new rate (changed in Audio MIDI Setup, or another device) needs a new processor.
        let sampleRate = isAdvanced ? ProcessAudioTap.defaultOutputSampleRate : nil

        if let current = tap as? ProcessAudioTap,
           current.processes == processes,
           current.outputDeviceUID == outputUID,
           current.isListening == isEnabled,
           adjustedSampleRate == sampleRate {
            return
        }
        stopTap()
        // The player may not have opened its audio yet; the timer tries again.
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
