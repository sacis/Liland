import Foundation
import ServiceManagement

enum Preferences {
    static let peekOnTrackChange = "peekOnTrackChange"

    static var shouldPeekOnTrackChange: Bool {
        UserDefaults.standard.object(forKey: peekOnTrackChange) as? Bool ?? false
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
