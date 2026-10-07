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

    /// Without artwork after this long, the track is shown without it (it can still arrive later).
    private static let artworkWait: TimeInterval = 1.5
    /// The macOS version on which the adapter last reported something, see `isKnownToWork`.
    private static let workingSystemKey = "systemNowPlayingWorksOn"

    let id = "system"
    let permissionDenied = false

    private(set) var snapshot: PlayerSnapshot?
    private var app: SourceApp?

    /// True once the adapter has reported media on this version of macOS, so the island
    /// can say that any app works. Reset by a macOS update, which may have closed the way.
    private(set) var isKnownToWork: Bool

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let adapter: MediaRemoteAdapter?
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

    init(ignoring bundleIdentifiers: Set<String>, adapter: MediaRemoteAdapter? = MediaRemoteAdapter()) {
        ignoredBundleIdentifiers = bundleIdentifiers
        self.adapter = adapter
        isKnownToWork = UserDefaults.standard.string(forKey: Self.workingSystemKey) == Self.systemVersion
    }

    func start() {
        adapter?.onUpdate = { [weak self] state in self?.apply(state) }
        adapter?.start()
    }

    /// The stream is live, so there is nothing to ask for.
    func refresh() {}

    // MARK: - Reading state

    private func apply(_ state: [String: Any]) {
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
            duration: Self.seconds(state["durationMicros"]) ?? 0,
            artworkURL: nil
        )
        let timestamp = Self.seconds(state["timestampEpochMicros"]).map(Date.init(timeIntervalSince1970:))
        let snapshot = PlayerSnapshot(
            track: track,
            isPlaying: state["playing"] as? Bool ?? false,
            position: Self.seconds(state["elapsedTimeMicros"]) ?? 0,
            positionDate: timestamp ?? Date()
        )
        update(app: app, snapshot: snapshot, artworkData: state["artworkData"] as? Data)
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

    private static func seconds(_ micros: Any?) -> TimeInterval? {
        (micros as? NSNumber).map { $0.doubleValue / 1_000_000 }
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
        adapter?.send(.togglePlayPause)
    }

    func nextTrack() {
        adapter?.send(.nextTrack)
    }

    func previousTrack() {
        adapter?.send(.previousTrack)
    }

    func seek(to seconds: TimeInterval) {
        if var snapshot {
            snapshot.position = seconds
            snapshot.positionDate = Date()
            self.snapshot = snapshot
            onChange?()
        }
        adapter?.seek(to: seconds)
    }

    // MARK: - App

    func open() {
        guard let url = app?.url else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
