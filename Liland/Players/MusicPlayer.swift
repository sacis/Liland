import AppKit

/// One source of what's playing that the island can show and control.
protocol MusicPlayer: AnyObject {
    /// Stays the same for the player's lifetime; the controller keys its history by it.
    var id: String { get }
    /// The app making the sound, for the equalizer to listen to.
    var audioBundleIdentifier: String? { get }
    var displayName: String { get }
    var icon: NSImage? { get }
    var isInstalled: Bool { get }
    var isRunning: Bool { get }
    var permissionDenied: Bool { get }
    var snapshot: PlayerSnapshot? { get }
    var onChange: (() -> Void)? { get set }

    func start()
    func refresh()
    /// May call `completion` again for the same track when better artwork arrives.
    func loadArtwork(for track: NowPlayingTrack, completion: @escaping (NSImage?) -> Void)
    func playPause()
    func nextTrack()
    func previousTrack()
    func seek(to seconds: TimeInterval)
    /// Does nothing when the snapshot has no shuffle state.
    func toggleShuffle()
    /// Off → all → one → off. Does nothing when the snapshot has no repeat mode.
    func cycleRepeat()
    func open()
}
