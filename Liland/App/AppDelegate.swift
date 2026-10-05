import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let nowPlaying = NowPlayingController()
    private var notchController: NotchWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = NotchWindowController(nowPlaying: nowPlaying)
        controller.show()
        notchController = controller
        nowPlaying.start()
    }
}
