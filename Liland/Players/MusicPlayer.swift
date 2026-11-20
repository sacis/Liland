import AppKit

protocol MusicPlayer: AnyObject {
    var id: String { get }
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
    func loadArtwork(for track: NowPlayingTrack, completion: @escaping (NSImage?) -> Void)
    func playPause()
    func nextTrack()
    func previousTrack()
    func seek(to seconds: TimeInterval)
    func toggleShuffle()
    func cycleRepeat()
    func open()
    func openAlbum()
}
