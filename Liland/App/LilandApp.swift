import SwiftUI

@main
struct LilandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Liland", image: "MenuBarIcon") {
            MenuContent(nowPlaying: appDelegate.nowPlaying)
        }
    }
}

private struct MenuContent: View {
    let nowPlaying: NowPlayingController

    @AppStorage(Preferences.peekOnTrackChange) private var peekOnTrackChange = false
    @AppStorage(Preferences.openOnClick) private var openOnClick = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    private var audioLevels: AudioLevelMonitor { nowPlaying.audioLevels }

    /// Turning the option on after saying no goes straight to Settings, where it can be allowed.
    private var followsMusic: Binding<Bool> {
        Binding {
            audioLevels.isEnabled
        } set: { enabled in
            audioLevels.isEnabled = enabled
            if enabled && AudioCapturePermission.status == .denied {
                AudioCapturePermission.openSettings()
            }
        }
    }

    var body: some View {
        Toggle("Show When the Song Changes", isOn: $peekOnTrackChange)
        // The label names the mode the user can switch to, not the current one.
        Button(openOnClick ? "Open on Hover" : "Open Only on Click") { openOnClick.toggle() }
        if audioLevels.isSupported {
            Toggle("Equalizer Follows the Music", isOn: followsMusic)
            if audioLevels.isEnabled && audioLevels.permission == .denied {
                Button("Allow Audio Access in Settings…", action: AudioCapturePermission.openSettings)
            }
        }
        Toggle("Open at Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { _, enabled in
                LaunchAtLogin.set(enabled)
                launchAtLogin = LaunchAtLogin.isEnabled
            }
        switch nowPlaying.systemPlayer.access {
        case .needsApproval:
            Button("Turn On Deezer and Browsers…", action: nowPlaying.systemPlayer.turnOn)
        case .awaitingApproval:
            Button("Turn On Deezer and Browsers…", action: SystemPlayer.openPrivacySettings)
        case .unavailable, .ready:
            EmptyView()
        }
        Divider()
        ForEach(nowPlaying.players.filter(\.isInstalled), id: \.id) { player in
            Button("Open \(player.displayName)") { player.open() }
        }
        Divider()
        Button("Quit Liland") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
