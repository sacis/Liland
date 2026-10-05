import SwiftUI

@main
struct LilandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Liland", systemImage: "capsule.fill") {
            MenuContent(nowPlaying: appDelegate.nowPlaying)
        }
    }
}

private struct MenuContent: View {
    let nowPlaying: NowPlayingController

    @AppStorage(Preferences.peekOnTrackChange) private var peekOnTrackChange = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Toggle("Show When the Song Changes", isOn: $peekOnTrackChange)
        Toggle("Open at Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { _, enabled in
                LaunchAtLogin.set(enabled)
                launchAtLogin = LaunchAtLogin.isEnabled
            }
        Divider()
        ForEach(nowPlaying.players.filter(\.isInstalled)) { player in
            Button("Open \(player.displayName)", action: player.open)
        }
        Divider()
        Button("Quit Liland") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
