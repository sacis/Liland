import AppKit

/// Permission to hear other apps' audio ("System Audio Recording Only" in Privacy & Security).
///
/// macOS has no public API to check or request it, so this calls the same TCC functions
/// the system uses. If they're ever missing, starting a tap still makes macOS ask.
enum AudioCapturePermission {
    enum Status { case unknown, authorized, denied }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user hasn't answered yet. Calls back on the main queue.
    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessRequest") else {
            completion(true)
            return
        }
        unsafeBitCast(symbol, to: Request.self)(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// Opens Screen & System Audio Recording, where "System Audio Recording Only" lives.
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}
