import Foundation

/// NSAppleScript isn't thread-safe (mangled results), so scripts run serially. Call off main.
enum AppleScript {
    private static let lock = NSLock()

    struct Failure: Error {
        let code: Int
        let message: String

        /// errAEEventNotPermitted: Automation access denied in System Settings.
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
