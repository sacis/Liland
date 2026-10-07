import Foundation
import ServiceManagement

enum Preferences {
    static let peekOnTrackChange = "peekOnTrackChange"
    static let openOnClick = "openOnClick"
    static let equalizerFollowsMusic = "equalizerFollowsMusic"

    static var shouldPeekOnTrackChange: Bool {
        UserDefaults.standard.object(forKey: peekOnTrackChange) as? Bool ?? false
    }

    /// When true, the island opens only when the notch is clicked, not on hover.
    static var shouldOpenOnClick: Bool {
        UserDefaults.standard.object(forKey: openOnClick) as? Bool ?? false
    }

    /// When true, the equalizer bars follow the music's real sound instead of a fixed animation.
    static var shouldEqualizerFollowMusic: Bool {
        UserDefaults.standard.object(forKey: equalizerFollowsMusic) as? Bool ?? false
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Liland: could not change launch at login: \(error)")
        }
    }
}
