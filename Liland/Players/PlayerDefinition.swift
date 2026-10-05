import Foundation

/// Describes a music app that Liland reads and controls through AppleScript.
/// Adding another scriptable player means adding another definition here.
struct PlayerDefinition {
    let bundleIdentifier: String
    /// Distributed notification the app posts on every play, pause and track change.
    let notificationName: String
    /// AppleScript expression (with the current track bound to `t`) for a stable track id.
    let trackIDExpression: String
    /// AppleScript expression for the cover URL, or nil when the cover is read as image data.
    let artworkURLExpression: String?

    static let spotify = PlayerDefinition(
        bundleIdentifier: "com.spotify.client",
        notificationName: "com.spotify.client.PlaybackStateChanged",
        trackIDExpression: "id of t",
        artworkURLExpression: "artwork url of t"
    )

    static let appleMusic = PlayerDefinition(
        bundleIdentifier: "com.apple.Music",
        notificationName: "com.apple.Music.playerInfo",
        trackIDExpression: "persistent ID of t",
        artworkURLExpression: nil
    )

    private var app: String { "application id \"\(bundleIdentifier)\"" }

    /// Returns {state, id, name, artist, album, duration, position, artwork URL}.
    /// Checks `is running` first so that querying never launches the app.
    var statusScript: String {
        """
        if \(app) is not running then return {"notrunning"}
        tell \(app)
            set playerState to player state as string
            if playerState is "stopped" then return {"stopped"}
            try
                set t to current track
                return {playerState, \(trackIDExpression), name of t, artist of t, album of t, duration of t, player position, \(artworkURLExpression ?? "\"\"")}
            on error
                return {"stopped"}
            end try
        end tell
        """
    }

    var artworkDataScript: String {
        """
        tell \(app)
            try
                return raw data of artwork 1 of current track
            on error
                return ""
            end try
        end tell
        """
    }

    func commandScript(_ command: String) -> String {
        "tell \(app) to \(command)"
    }
}
