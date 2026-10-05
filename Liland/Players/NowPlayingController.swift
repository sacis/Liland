import AppKit
import Observation
import SwiftUI

/// Combines every supported player into the one the island shows:
/// the player that most recently started playing, or else the one used last.
@Observable
final class NowPlayingController {
    static let defaultAccent = Color(red: 0.12, green: 0.84, blue: 0.38)

    let players: [ScriptablePlayer]

    private(set) var activePlayer: ScriptablePlayer?
    private(set) var artwork: NSImage?
    private(set) var accentColor = NowPlayingController.defaultAccent

    /// Called once a new song's artwork has loaded (or failed to).
    @ObservationIgnored var onTrackChange: (() -> Void)?

    private struct Seen: Equatable {
        let trackID: String?
        let isPlaying: Bool
    }

    @ObservationIgnored private var lastSeen: [String: Seen] = [:]
    @ObservationIgnored private var lastActivity: [String: Date] = [:]
    @ObservationIgnored private var artworkKey: String?
    @ObservationIgnored private let startDate = Date()

    init(players: [ScriptablePlayer] = [
        ScriptablePlayer(definition: .spotify),
        ScriptablePlayer(definition: .appleMusic),
    ]) {
        self.players = players
    }

    func start() {
        for player in players {
            player.onChange = { [weak self] in self?.update() }
            player.start()
        }
    }

    func refresh() {
        players.filter(\.isRunning).forEach { $0.refresh() }
    }

    // MARK: - State for the views

    var track: NowPlayingTrack? { activePlayer?.snapshot?.track }
    var isPlaying: Bool { activePlayer?.snapshot?.isPlaying ?? false }

    func currentPosition(at date: Date) -> TimeInterval {
        activePlayer?.snapshot?.elapsed(at: date) ?? 0
    }

    /// A running player Liland isn't allowed to read, to explain why nothing shows.
    var deniedPlayer: ScriptablePlayer? {
        players.first { $0.isRunning && $0.permissionDenied }
    }

    /// The player to offer when nothing is playing: the one used last, else the first installed.
    var preferredPlayer: ScriptablePlayer? {
        mostRecent(players.filter(\.isInstalled))
    }

    // MARK: - Commands

    func playPause() { activePlayer?.playPause() }
    func nextTrack() { activePlayer?.nextTrack() }
    func previousTrack() { activePlayer?.previousTrack() }
    func seek(to seconds: TimeInterval) { activePlayer?.seek(to: seconds) }

    // MARK: - Choosing the active player

    private func update() {
        let now = Date()
        for player in players {
            let seen = Seen(trackID: player.snapshot?.track.id, isPlaying: player.snapshot?.isPlaying ?? false)
            if seen.isPlaying && seen != lastSeen[player.id] {
                lastActivity[player.id] = now
            }
            lastSeen[player.id] = seen
        }

        let available = players.filter { $0.snapshot != nil }
        let chosen = mostRecent(available.filter { $0.snapshot?.isPlaying == true }) ?? mostRecent(available)
        if chosen !== activePlayer {
            activePlayer = chosen
        }

        let key = chosen.flatMap { player in player.snapshot.map { "\(player.id)|\($0.track.id)" } }
        if key != artworkKey {
            let isSongChange = artworkKey != nil || now.timeIntervalSince(startDate) > 3
            artworkKey = key
            loadArtwork(key: key, announce: isSongChange)
        }
    }

    /// Most recent activity wins; ties keep the order of `players` (Spotify first).
    private func mostRecent(_ candidates: [ScriptablePlayer]) -> ScriptablePlayer? {
        var best: ScriptablePlayer?
        var bestDate = Date.distantPast
        for player in candidates {
            let date = lastActivity[player.id] ?? .distantPast
            if best == nil || date > bestDate {
                best = player
                bestDate = date
            }
        }
        return best
    }

    private func loadArtwork(key: String?, announce: Bool) {
        artwork = nil
        accentColor = Self.defaultAccent
        guard key != nil, let player = activePlayer, let track = player.snapshot?.track else { return }

        player.loadArtwork(for: track) { [weak self] image in
            guard let self, self.artworkKey == key else { return }
            self.artwork = image
            self.accentColor = image.flatMap(ArtworkColor.accent(for:)).map(Color.init(nsColor:)) ?? Self.defaultAccent
            if announce { self.onTrackChange?() }
        }
    }
}
