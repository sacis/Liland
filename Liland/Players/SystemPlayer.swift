import AppKit
import Observation

/// Whatever the system shows as Now Playing in Control Center: Deezer, TIDAL,
/// YouTube or any site in a browser…
///
/// Apps that have their own `ScriptablePlayer` are ignored here, so that Spotify and
/// Apple Music keep working through AppleScript even if Apple closes this way.
@Observable
final class SystemPlayer: MusicPlayer {
    private struct SourceApp: Equatable {
        /// The app the user knows, e.g. Safari rather than its WebKit process.
        let bundleIdentifier: String
        /// The process that reports the media, which is the one making the sound.
        let reportingBundleIdentifier: String
        let url: URL?
        let name: String
        let icon: NSImage?

        static func == (lhs: SourceApp, rhs: SourceApp) -> Bool {
            lhs.bundleIdentifier == rhs.bundleIdentifier && lhs.reportingBundleIdentifier == rhs.reportingBundleIdentifier
        }
    }

    enum Access: Equatable {
        /// The helper can't run here, e.g. a future macOS without Perl.
        case unavailable
        /// A downloaded copy whose helper the user hasn't allowed yet.
        case needsApproval
        /// The user chose to turn it on; macOS holds the helper until they click
        /// Open Anyway in Privacy & Security.
        case awaitingApproval
        case ready
    }

    /// Without artwork after this long, the track is shown without it (it can still arrive later).
    private static let artworkWait: TimeInterval = 1.5
    /// How long the helper may wait for the user to allow it in Privacy & Security.
    private static let approvalPatience: TimeInterval = 600
    /// The macOS version on which the helper last reported something, see `isKnownToWork`.
    private static let workingSystemKey = "systemNowPlayingWorksOn"
    /// The helper build the user allowed, so it isn't asked for again until it changes.
    private static let approvedHelperKey = "approvedNowPlayingHelper"

    let id = "system"
    let permissionDenied = false

    private(set) var snapshot: PlayerSnapshot?
    private(set) var access = Access.unavailable
    private var app: SourceApp?

    /// True once the helper has reported media on this version of macOS, so the island
    /// can say that any app works. Reset by a macOS update, which may have closed the way.
    private(set) var isKnownToWork: Bool

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let bridge: MediaRemoteBridge?
    @ObservationIgnored private let ignoredBundleIdentifiers: Set<String>
    @ObservationIgnored private var artworkData: Data?
    @ObservationIgnored private var artworkImage: NSImage?
    @ObservationIgnored private var artworkRequest: (trackID: String, completion: (NSImage?) -> Void)?
    @ObservationIgnored private var deliveredImage: NSImage?

    var audioBundleIdentifier: String? { app?.reportingBundleIdentifier }
    var displayName: String { app?.name ?? "" }
    var icon: NSImage? { app?.icon }
    var isInstalled: Bool { app?.url != nil }
    var isRunning: Bool { snapshot != nil }

    init(ignoring bundleIdentifiers: Set<String>, bridge: MediaRemoteBridge? = MediaRemoteBridge()) {
        ignoredBundleIdentifiers = bundleIdentifiers
        self.bridge = bridge
        isKnownToWork = UserDefaults.standard.string(forKey: Self.workingSystemKey) == Self.systemVersion
    }

    func start() {
        guard let bridge else { return }
        bridge.onUpdate = { [weak self] state, artwork in self?.apply(state, artwork: artwork) }
        bridge.onReady = { [weak self] in self?.helperAnswered() }
        bridge.onStuck = { [weak self] in self?.helperStuck() }

        // Never load an unapproved helper on its own: macOS would show its alert out of the blue.
        if bridge.isQuarantined && UserDefaults.standard.string(forKey: Self.approvedHelperKey) != bridge.helperIdentity {
            access = .needsApproval
        } else {
            access = .ready
            bridge.start()
        }
    }

    // MARK: - Allowing the helper

    /// Loads the helper, which makes macOS show its alert, then opens Privacy & Security
    /// where the user clicks Open Anyway, as they did for Liland itself.
    func turnOn() {
        guard access == .needsApproval, let bridge else { return }
        access = .awaitingApproval
        bridge.start(patience: Self.approvalPatience)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard self?.access == .awaitingApproval else { return }
            Self.openPrivacySettings()
        }
    }

    static func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") else { return }
        NSWorkspace.shared.open(url)
    }

    private func helperAnswered() {
        if let bridge, bridge.isQuarantined {
            UserDefaults.standard.set(bridge.helperIdentity, forKey: Self.approvedHelperKey)
        }
        access = .ready
    }

    /// Stuck before its first answer: in a downloaded copy, macOS is holding it for approval
    /// (a new Liland version brings a new helper); otherwise this way doesn't work here.
    private func helperStuck() {
        if let bridge, bridge.isQuarantined {
            UserDefaults.standard.removeObject(forKey: Self.approvedHelperKey)
            access = .needsApproval
        } else {
            access = .unavailable
        }
    }

    /// The stream is live, so there is nothing to ask for.
    func refresh() {}

    // MARK: - Reading state

    private func apply(_ state: [String: Any], artwork: Data?) {
        guard let reporting = state["bundleIdentifier"] as? String,
              let title = state["title"] as? String
        else {
            update(app: nil, snapshot: nil, artworkData: nil)
            return
        }
        markWorking()

        let bundleID = state["parentApplicationBundleIdentifier"] as? String ?? reporting
        if ignoredBundleIdentifiers.contains(bundleID) || ignoredBundleIdentifiers.contains(reporting) {
            update(app: nil, snapshot: nil, artworkData: nil)
            return
        }

        let app = self.app.flatMap { $0.bundleIdentifier == bundleID && $0.reportingBundleIdentifier == reporting ? $0 : nil }
            ?? Self.sourceApp(bundleID, reporting: reporting)
        let artist = state["artist"] as? String ?? ""
        let album = state["album"] as? String ?? ""
        let track = NowPlayingTrack(
            id: [bundleID, title, artist, album].joined(separator: "|"),
            title: title,
            artist: artist,
            album: album,
            duration: Self.number(state["duration"]) ?? 0,
            artworkURL: nil
        )
        let timestamp = Self.number(state["timestamp"]).map(Date.init(timeIntervalSince1970:))
        // MediaRemote's shuffle modes: 1 off, 2 albums, 3 songs. Many players don't report one.
        let shuffleMode = Self.number(state["shuffleMode"]).map(Int.init)
        let snapshot = PlayerSnapshot(
            track: track,
            isPlaying: state["playing"] as? Bool ?? false,
            position: Self.number(state["elapsedTime"]) ?? 0,
            positionDate: timestamp ?? Date(),
            isShuffling: shuffleMode.flatMap { (1...3).contains($0) ? $0 != 1 : nil },
            repeatMode: Self.number(state["repeatMode"]).flatMap { RepeatMode(mediaRemoteValue: Int($0)) }
        )
        update(app: app, snapshot: snapshot, artworkData: artwork)
    }

    private func update(app: SourceApp?, snapshot: PlayerSnapshot?, artworkData: Data?) {
        if app != self.app { self.app = app }

        if artworkData != self.artworkData {
            self.artworkData = artworkData
            artworkImage = artworkData.flatMap(NSImage.init(data:))
        }

        if snapshot != self.snapshot {
            self.snapshot = snapshot
            // On a new track, the controller asks for its artwork from here.
            onChange?()
        }
        deliverArtwork()
    }

    private func markWorking() {
        guard !isKnownToWork else { return }
        isKnownToWork = true
        UserDefaults.standard.set(Self.systemVersion, forKey: Self.workingSystemKey)
    }

    private static var systemVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func sourceApp(_ bundleID: String, reporting: String) -> SourceApp {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name = url.map { url in
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        } ?? bundleID
        return SourceApp(
            bundleIdentifier: bundleID,
            reportingBundleIdentifier: reporting,
            url: url,
            name: name,
            icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        )
    }

    // MARK: - Artwork

    /// Artwork often arrives after the title. The request stays open while its track is
    /// current, so the cover shows up as soon as it comes, and changes if the player sends a new one.
    func loadArtwork(for track: NowPlayingTrack, completion: @escaping (NSImage?) -> Void) {
        artworkRequest = (track.id, completion)
        deliveredImage = artworkImage
        if let artworkImage {
            completion(artworkImage)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.artworkWait) { [weak self] in
            guard let self, self.artworkImage == nil, self.artworkRequest?.trackID == track.id else { return }
            completion(nil)
        }
    }

    private func deliverArtwork() {
        guard let request = artworkRequest else { return }
        guard request.trackID == snapshot?.track.id else {
            artworkRequest = nil
            deliveredImage = nil
            return
        }
        guard let artworkImage, artworkImage !== deliveredImage else { return }
        deliveredImage = artworkImage
        request.completion(artworkImage)
    }

    // MARK: - Commands

    func playPause() {
        if var snapshot {
            snapshot.position = snapshot.elapsed(at: Date())
            snapshot.positionDate = Date()
            snapshot.isPlaying.toggle()
            self.snapshot = snapshot
            onChange?()
        }
        bridge?.send(.togglePlayPause)
    }

    func nextTrack() {
        bridge?.send(.nextTrack)
    }

    func previousTrack() {
        bridge?.send(.previousTrack)
    }

    func seek(to seconds: TimeInterval) {
        if var snapshot {
            snapshot.position = seconds
            snapshot.positionDate = Date()
            self.snapshot = snapshot
            onChange?()
        }
        bridge?.send(.seek(seconds))
    }

    func toggleShuffle() {
        guard var snapshot, let isShuffling = snapshot.isShuffling else { return }
        snapshot.isShuffling = !isShuffling
        self.snapshot = snapshot
        onChange?()
        bridge?.send(.shuffle(!isShuffling))
    }

    func cycleRepeat() {
        guard var snapshot, let mode = snapshot.repeatMode else { return }
        let next: RepeatMode = switch mode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
        snapshot.repeatMode = next
        self.snapshot = snapshot
        onChange?()
        bridge?.send(.repeatMode(next))
    }

    // MARK: - App

    func open() {
        guard let url = app?.url else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
