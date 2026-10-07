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
    /// Safari reports some sites, such as Deezer, as paused while they play. They send the
    /// position twice a second while playing and go quiet once paused, so a moving position
    /// counts as playing until no update has arrived for this long.
    private static let positionSilence: TimeInterval = 3
    /// Notification sounds, such as a new message in WhatsApp Web, briefly take over the
    /// browser's Now Playing. Media shorter than this isn't music and is ignored.
    private static let shortestMedia: TimeInterval = 5
    /// MediaRemote sometimes reports nothing for a split second while the song plays on.
    /// Nothing has to last this long before the song goes away.
    private static let emptyPatience: TimeInterval = 1.5
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
    @ObservationIgnored private let scriptQueue = DispatchQueue(label: "com.flaviasilva.Liland.SystemPlayer")
    @ObservationIgnored private var artworkData: Data?
    @ObservationIgnored private var artworkImage: NSImage?
    @ObservationIgnored private var artworkRequest: (trackID: String, completion: (NSImage?) -> Void)?
    @ObservationIgnored private var deliveredImage: NSImage?
    @ObservationIgnored private var lastPosition: (trackID: String, elapsed: TimeInterval)?
    @ObservationIgnored private var silenceWork: DispatchWorkItem?
    @ObservationIgnored private var clearWork: DispatchWorkItem?
    /// Whether each track is music, once known; see `isMusic`.
    @ObservationIgnored private var musicVerdicts: [String: Bool] = [:]
    @ObservationIgnored private var checkingTrackIDs: Set<String> = []
    /// The latest state, held while its browser is asked whether it comes from a music service.
    @ObservationIgnored private var pending: (trackID: String, state: [String: Any], artwork: Data?)?
    /// Recent songs' artwork: a song that gets its place back from other media comes without it.
    @ObservationIgnored private var recentArtwork: [(trackID: String, data: Data)] = []

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
        pending = nil
        clearWork?.cancel()
        clearWork = nil
        // Notification sounds don't need asking whether they're music.
        if let duration = Self.number(state["duration"]), duration > 0, duration < Self.shortestMedia {
            otherMediaReported(state)
            return
        }
        guard let reporting = state["bundleIdentifier"] as? String,
              let title = state["title"] as? String
        else {
            silenceWork?.cancel()
            silenceWork = nil
            scheduleClear()
            return
        }
        markWorking()

        let bundleID = state["parentApplicationBundleIdentifier"] as? String ?? reporting
        if ignoredBundleIdentifiers.contains(bundleID) || ignoredBundleIdentifiers.contains(reporting) {
            silenceWork?.cancel()
            silenceWork = nil
            update(app: nil, snapshot: nil, artworkData: nil)
            return
        }

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
        switch isMusic(track, from: bundleID) {
        case nil:
            pending = (track.id, state, artwork)
            return
        case false?:
            otherMediaReported(state)
            return
        case true?:
            break
        }
        silenceWork?.cancel()
        silenceWork = nil

        let app = self.app.flatMap { $0.bundleIdentifier == bundleID && $0.reportingBundleIdentifier == reporting ? $0 : nil }
            ?? Self.sourceApp(bundleID, reporting: reporting)
        let timestamp = Self.number(state["timestamp"]).map(Date.init(timeIntervalSince1970:))
        // MediaRemote's shuffle modes: 1 off, 2 albums, 3 songs. Many players don't report one.
        let shuffleMode = Self.number(state["shuffleMode"]).map(Int.init)
        let elapsed = Self.number(state["elapsedTime"]) ?? 0
        let isReportedPlaying = state["playing"] as? Bool ?? false
        // A new song can't have moved yet; it carries on from the previous one.
        let wasPlaying = self.snapshot?.isPlaying ?? false
        let isMoving = lastPosition.map { $0.trackID == track.id ? $0.elapsed != elapsed : wasPlaying } ?? false
        lastPosition = (track.id, elapsed)
        let snapshot = PlayerSnapshot(
            track: track,
            isPlaying: isReportedPlaying || isMoving,
            position: elapsed,
            positionDate: timestamp ?? Date(),
            isShuffling: shuffleMode.flatMap { (1...3).contains($0) ? $0 != 1 : nil },
            repeatMode: Self.number(state["repeatMode"]).flatMap { RepeatMode(mediaRemoteValue: Int($0)) }
        )
        if let artwork { remember(artwork, for: track.id) }
        let artwork = artwork ?? recentArtwork.last { $0.trackID == track.id }?.data
        update(app: app, snapshot: snapshot, artworkData: artwork)
        if isMoving && !isReportedPlaying {
            scheduleSilenceCheck()
        }
    }

    /// Music services and music apps, not a WhatsApp voice message or an Instagram video.
    /// Browsers are asked which site the media comes from, once per track; meanwhile this is
    /// nil and the state waits in `pending`. Elsewhere, music is what names an artist.
    private func isMusic(_ track: NowPlayingTrack, from bundleID: String) -> Bool? {
        if let verdict = musicVerdicts[track.id] { return verdict }
        guard BrowserTab.canInspect(bundleID) else {
            return record(!track.artist.isEmpty, for: track.id)
        }
        guard checkingTrackIDs.insert(track.id).inserted else { return nil }
        scriptQueue.async { [weak self] in
            let verdict = BrowserTab.isMusicSite(track, in: bundleID) ?? !track.artist.isEmpty
            DispatchQueue.main.async {
                guard let self else { return }
                self.checkingTrackIDs.remove(track.id)
                self.record(verdict, for: track.id)
                if let pending = self.pending, pending.trackID == track.id {
                    self.apply(pending.state, artwork: pending.artwork)
                }
            }
        }
        return nil
    }

    @discardableResult
    private func record(_ verdict: Bool, for trackID: String) -> Bool {
        if musicVerdicts.count > 500 { musicVerdicts.removeAll() }
        musicVerdicts[trackID] = verdict
        return verdict
    }

    private func remember(_ artwork: Data, for trackID: String) {
        recentArtwork.removeAll { $0.trackID == trackID }
        recentArtwork.append((trackID, artwork))
        if recentArtwork.count > 10 { recentArtwork.removeFirst() }
    }

    /// Other media holds the system's Now Playing (a voice message, a video, a notification
    /// sound) and plays over the song, which keeps its place. Nothing comes from the song
    /// meanwhile, so it only counts as paused once the other media has stopped and the song
    /// still hasn't come back.
    private func otherMediaReported(_ state: [String: Any]) {
        silenceWork?.cancel()
        silenceWork = nil
        if state["playing"] as? Bool != true {
            scheduleSilenceCheck()
        }
    }

    /// Lets the song go once nothing has been reported for a moment, so a blip doesn't hide it.
    private func scheduleClear() {
        guard snapshot != nil else {
            update(app: nil, snapshot: nil, artworkData: nil)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.clearWork = nil
            self?.update(app: nil, snapshot: nil, artworkData: nil)
        }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.emptyPatience, execute: work)
    }

    /// Shows a site that stopped sending its position as paused.
    private func scheduleSilenceCheck() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, var snapshot = self.snapshot, snapshot.isPlaying else { return }
            snapshot.isPlaying = false
            self.snapshot = snapshot
            self.onChange?()
        }
        silenceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.positionSilence, execute: work)
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

    /// Says which one, play or pause: Safari can think a playing site is paused, and its
    /// own toggle would then play it again instead of pausing.
    func playPause() {
        let shouldPause = snapshot?.isPlaying ?? false
        if var snapshot {
            snapshot.position = snapshot.elapsed(at: Date())
            snapshot.positionDate = Date()
            snapshot.isPlaying = !shouldPause
            self.snapshot = snapshot
            onChange?()
        }
        silenceWork?.cancel()
        silenceWork = nil
        if shouldPause {
            // A position already on its way mustn't count as still playing.
            lastPosition = nil
        } else {
            // Undone if the song doesn't start, e.g. when Safari sends the command to the
            // tab that made the last sound, such as WhatsApp Web, instead of the song's.
            scheduleSilenceCheck()
        }
        bridge?.send(shouldPause ? .pause : .play)
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

    /// In a browser, goes straight to the tab the song plays in when it can find it.
    func open() {
        guard let app, let url = app.url else { return }
        let track = snapshot?.track
        scriptQueue.async {
            if let track, BrowserTab.show(track, in: app.bundleIdentifier) { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }
}
