import Foundation

/// Runs AppleScript source synchronously. Call it off the main thread.
///
/// NSAppleScript isn't safe to run on several threads at once (it can hand back mangled
/// results), so scripts run one at a time, each given `timeout` seconds to get an answer
/// from the app before failing, so an app that hangs can't hold up the others for long.
enum AppleScript {
    private static let lock = NSLock()

    struct Failure: Error {
        let code: Int
        let message: String

        /// errAEEventNotPermitted: the user denied Automation access in System Settings.
        var isPermissionDenied: Bool { code == -1743 }
    }

    static func run(_ source: String, timeout: Int = 5) -> Result<NSAppleEventDescriptor, Failure> {
        lock.lock()
        defer { lock.unlock() }
        guard let script = NSAppleScript(source: "with timeout of \(timeout) seconds\n\(source)\nend timeout") else {
            return .failure(Failure(code: -1, message: "Could not create script"))
        }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let error {
            return .failure(Failure(
                code: error[NSAppleScript.errorNumber] as? Int ?? -1,
                message: error[NSAppleScript.errorMessage] as? String ?? ""
            ))
        }
        return .success(output)
    }
}
