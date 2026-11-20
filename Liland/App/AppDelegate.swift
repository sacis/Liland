import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let nowPlaying = NowPlayingController()
    private var notchController: NotchWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        nowPlaying.dj.closeLeftoverCopy()
        let controller = NotchWindowController(nowPlaying: nowPlaying)
        controller.show()
        notchController = controller
        nowPlaying.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        nowPlaying.dj.exit()
    }
}
