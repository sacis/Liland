import AppKit
import Observation

/// Live state of one scriptable music app (Spotify, Apple Music).
///
/// The app's distributed notification triggers a refresh, and the full state is
/// read through AppleScript. A slow poll catches changes made from other devices.
@Observable
final class ScriptablePlayer: Identifiable {
    let definition: PlayerDefinition
    let appURL: URL?
    let displayName: String
    let icon: NSImage?

    private(set) var isRunning = false
    private(set) var permissionDenied = false
    private(set) var snapshot: PlayerSnapshot?

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let queue: DispatchQueue
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var pollTimer: Timer?

    var id: String { definition.bundleIdentifier }
    var isInstalled: Bool { appURL != nil }

    init(definition: PlayerDefinition) {
        self.definition = definition
        appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: definition.bundleIdentifier)
        // The Finder name is localized ("Música" in Portuguese, "Musique" in French…).
        displayName = appURL.map { url in
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        } ?? definition.bundleIdentifier
        icon = appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        queue = DispatchQueue(label: "com.flaviasilva.Liland.\(definition.bundleIdentifier)")
    }

    deinit {
        observers.forEach { center, token in center.removeObserver(token) }
        pollTimer?.invalidate()
    }

    func start() {
        guard isInstalled else { return }
        isRunning = runningApplication != nil

        observe(DistributedNotificationCenter.default(), Notification.Name(definition.notificationName)) { [weak self] note in
            self?.handlePlaybackNotification(note)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didLaunchApplicationNotification) { [weak self] note in
            guard let self, self.isOwnApp(note) else { return }
            self.isRunning = true
            self.refresh(after: 1)
        }
        observe(workspace, NSWorkspace.didTerminateApplicationNotification) { [weak self] note in
            guard let self, self.isOwnApp(note) else { return }
            self.applyNotRunning()
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.refresh()
        }
        pollTimer?.tolerance = 1

        refresh()
    }

    // MARK: - Reading state

    func refresh(after delay: TimeInterval = 0) {
        guard isInstalled, runningApplication != nil else {
            applyNotRunning()
            return
        }
        let script = definition.statusScript
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            let result = AppleScript.run(script)
            DispatchQueue.main.async { self?.apply(result) }
        }
    }

    private func apply(_ result: Result<NSAppleEventDescriptor, AppleScript.Failure>) {
        switch result {
        case .failure(let failure):
            if failure.isPermissionDenied {
                permissionDenied = true
                setSnapshot(nil)
            } else {
                NSLog("Liland: \(displayName) script error \(failure.code): \(failure.message)")
            }
        case .success(let output):
            permissionDenied = false
            switch output.atIndex(1)?.stringValue {
            case "notrunning", nil:
                applyNotRunning()
            case "stopped":
                isRunning = true
                setSnapshot(nil)
            case let state?:
                isRunning = true
                setSnapshot(Self.snapshot(from: output, state: state))
            }
        }
    }

    private static func snapshot(from output: NSAppleEventDescriptor, state: String) -> PlayerSnapshot {
        func string(_ index: Int) -> String { output.atIndex(index)?.stringValue ?? "" }
        let track = NowPlayingTrack(
            id: string(2),
            title: string(3),
            artist: string(4),
            album: string(5),
            duration: normalizedDuration(output.atIndex(6)?.doubleValue ?? 0),
            artworkURL: URL(string: string(8))
        )
        return PlayerSnapshot(
            track: track,
            // Apple Music also reports "fast forwarding" and "rewinding".
            isPlaying: state != "paused",
            position: output.atIndex(7)?.doubleValue ?? 0,
            positionDate: Date()
        )
    }

    /// Spotify's dictionary says seconds but returns milliseconds; Apple Music returns seconds.
    private static func normalizedDuration(_ value: Double) -> TimeInterval {
        value > 36_000 ? value / 1000 : value
    }

    private func applyNotRunning() {
        isRunning = false
        setSnapshot(nil)
    }

    private func handlePlaybackNotification(_ note: Notification) {
        // Both apps include "Player State" ("Playing", "Paused", "Stopped"):
        // update play/pause instantly and let the script fill in the rest.
        if let state = note.userInfo?["Player State"] as? String, var snapshot {
            snapshot.position = snapshot.elapsed(at: Date())
            snapshot.positionDate = Date()
            snapshot.isPlaying = state == "Playing"
            setSnapshot(snapshot)
        }
        refresh()
    }

    private func setSnapshot(_ newValue: PlayerSnapshot?) {
        guard newValue != snapshot else { return }
        snapshot = newValue
        onChange?()
    }

    // MARK: - Artwork

    func loadArtwork(for track: NowPlayingTrack, completion: @escaping (NSImage?) -> Void) {
        if let url = track.artworkURL {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                let image = data.flatMap(NSImage.init(data:))
                DispatchQueue.main.async { completion(image) }
            }.resume()
        } else {
            let script = definition.artworkDataScript
            queue.async {
                let data = try? AppleScript.run(script).get().data
                let image = data.flatMap(NSImage.init(data:))
                DispatchQueue.main.async { completion(image) }
            }
        }
    }

    // MARK: - Commands

    func playPause() {
        if var snapshot {
            snapshot.position = snapshot.elapsed(at: Date())
            snapshot.positionDate = Date()
            snapshot.isPlaying.toggle()
            setSnapshot(snapshot)
        }
        send("playpause")
    }

    func nextTrack() {
        send("next track")
    }

    func previousTrack() {
        send("previous track")
    }

    func seek(to seconds: TimeInterval) {
        if var snapshot {
            snapshot.position = seconds
            snapshot.positionDate = Date()
            setSnapshot(snapshot)
        }
        send("set player position to \(seconds)")
    }

    private func send(_ command: String) {
        let script = definition.commandScript(command)
        queue.async { [weak self] in
            let result = AppleScript.run(script)
            DispatchQueue.main.async {
                if case .failure(let failure) = result, failure.isPermissionDenied {
                    self?.permissionDenied = true
                }
                self?.refresh(after: 0.3)
            }
        }
    }

    // MARK: - App

    func open() {
        guard let appURL else { return }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    private var runningApplication: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: definition.bundleIdentifier).first
    }

    private func isOwnApp(_ note: Notification) -> Bool {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier == definition.bundleIdentifier
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, handler: @escaping (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main, using: handler)
        observers.append((center, token))
    }
}
