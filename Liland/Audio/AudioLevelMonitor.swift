import Foundation
import Observation

/// Listens to the active player so the equalizer can move with the music.
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

    var isSupported: Bool {
        if #available(macOS 14.4, *) { true } else { false }
    }

    @ObservationIgnored private var bundleID: String?
    @ObservationIgnored private var isPlaying = false
    @ObservationIgnored private var tap: AnyObject?
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
        guard isSupported, isEnabled else {
            stop()
            return
        }
        let status = AudioCapturePermission.status
        if status != permission { permission = status }

        let needsTimer = isPlaying || permission == .denied
        if needsTimer && timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.update() }
        } else if !needsTimer {
            timer?.invalidate()
            timer = nil
        }

        guard isPlaying, let bundleID else {
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

        if let current = tap as? ProcessAudioTap,
           current.processes == processes,
           current.outputDeviceUID == outputUID {
            return
        }
        stopTap()
        // The player may not have opened its audio yet; the timer tries again.
        guard !processes.isEmpty, let outputUID else { return }

        let outputLatency = ProcessAudioTap.defaultOutputLatency ?? 0
        NSLog("Liland: listening to %@ on %@ (output latency %.0f ms)", bundleID, outputUID, outputLatency * 1000)

        let analyzer = SpectrumAnalyzer()
        let levels = LiveLevels(delay: max(0, outputLatency - Self.analysisLatency))
        var hasDelivered = false
        starting = levels
        tap = ProcessAudioTap(processes: processes, outputDeviceUID: outputUID) { [weak self] samples, channels, sampleRate in
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

    private func stopTap() {
        tap = nil
        starting = nil
        if live != nil { live = nil }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        stopTap()
    }
}
