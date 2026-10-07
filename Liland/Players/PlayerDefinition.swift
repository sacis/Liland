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
    /// The app's boolean shuffle property.
    let shuffleProperty: String
    /// The app's repeat property: off/one/all when `canRepeatOne`, else a boolean.
    let repeatProperty: String
    let canRepeatOne: Bool

    static let spotify = PlayerDefinition(
        bundleIdentifier: "com.spotify.client",
        notificationName: "com.spotify.client.PlaybackStateChanged",
        trackIDExpression: "id of t",
        artworkURLExpression: "artwork url of t",
        shuffleProperty: "shuffling",
        repeatProperty: "repeating",
        canRepeatOne: false
    )

    static let appleMusic = PlayerDefinition(
        bundleIdentifier: "com.apple.Music",
        notificationName: "com.apple.Music.playerInfo",
        trackIDExpression: "persistent ID of t",
        artworkURLExpression: nil,
        shuffleProperty: "shuffle enabled",
        repeatProperty: "song repeat",
        canRepeatOne: true
    )

    private var app: String { "application id \"\(bundleIdentifier)\"" }

    /// Returns {state, id, name, artist, album, duration, position, artwork URL, shuffle, repeat}.
    /// Checks `is running` first so that querying never launches the app.
    /// Shuffle and repeat are "" when the app can't tell, which hides their buttons.
    var statusScript: String {
        """
        if \(app) is not running then return {"notrunning"}
        tell \(app)
            set playerState to player state as string
            if playerState is "stopped" then return {"stopped"}
            set shuffleState to ""
            set repeatState to ""
            try
                set shuffleState to \(shuffleProperty) as string
            end try
            try
                set repeatState to \(repeatProperty) as string
            end try
            try
                set t to current track
                return {playerState, \(trackIDExpression), name of t, artist of t, album of t, duration of t, player position, \(artworkURLExpression ?? "\"\""), shuffleState, repeatState}
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

    func shuffleCommand(_ isOn: Bool) -> String {
        "set \(shuffleProperty) to \(isOn)"
    }

    func repeatCommand(_ mode: RepeatMode) -> String {
        guard canRepeatOne else { return "set \(repeatProperty) to \(mode != .off)" }
        return switch mode {
        case .off: "set \(repeatProperty) to off"
        case .all: "set \(repeatProperty) to all"
        case .one: "set \(repeatProperty) to one"
        }
    }

    /// Reads the repeat property as `statusScript` returns it.
    func repeatMode(from value: String) -> RepeatMode? {
        switch value {
        case "true", "all": .all
        case "false", "off": .off
        case "one": .one
        default: nil
        }
    }

    func commandScript(_ command: String) -> String {
        "tell \(app) to \(command)"
    }
}
