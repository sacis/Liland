import Foundation

struct PlayerDefinition {
    let bundleIdentifier: String
    let notificationName: String
    /// AppleScript expression, with the current track bound to `t`.
    let trackIDExpression: String
    let artworkURLExpression: String?
    let shuffleProperty: String
    let repeatProperty: String
    let canRepeatOne: Bool
    let albumLink: AlbumLink

    static let spotify = PlayerDefinition(
        bundleIdentifier: "com.spotify.client",
        notificationName: "com.spotify.client.PlaybackStateChanged",
        trackIDExpression: "id of t",
        artworkURLExpression: "artwork url of t",
        shuffleProperty: "shuffling",
        repeatProperty: "repeating",
        canRepeatOne: false,
        albumLink: .spotify
    )

    static let appleMusic = PlayerDefinition(
        bundleIdentifier: "com.apple.Music",
        notificationName: "com.apple.Music.playerInfo",
        trackIDExpression: "persistent ID of t",
        artworkURLExpression: nil,
        shuffleProperty: "shuffle enabled",
        repeatProperty: "song repeat",
        canRepeatOne: true,
        albumLink: .appleMusic
    )

    private var app: String { "application id \"\(bundleIdentifier)\"" }

    /// Checks `is running` first so that querying never launches the app.
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
