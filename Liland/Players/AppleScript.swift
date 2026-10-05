import Foundation

/// Runs AppleScript source synchronously. Call it off the main thread.
enum AppleScript {
    struct Failure: Error {
        let code: Int
        let message: String

        /// errAEEventNotPermitted: the user denied Automation access in System Settings.
        var isPermissionDenied: Bool { code == -1743 }
    }

    static func run(_ source: String) -> Result<NSAppleEventDescriptor, Failure> {
        guard let script = NSAppleScript(source: source) else {
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
