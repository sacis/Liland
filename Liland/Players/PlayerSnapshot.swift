import Foundation

struct NowPlayingTrack: Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    /// Zero for live streams such as radio stations.
    let duration: TimeInterval
    let artworkURL: URL?
}

/// One player's state at a moment in time.
struct PlayerSnapshot: Equatable {
    var track: NowPlayingTrack
    var isPlaying: Bool
    /// Playback position at `positionDate`.
    var position: TimeInterval
    var positionDate: Date

    /// Position extrapolated to `date` while playing.
    func elapsed(at date: Date) -> TimeInterval {
        let value = position + (isPlaying ? date.timeIntervalSince(positionDate) : 0)
        guard track.duration > 0 else { return max(value, 0) }
        return min(max(value, 0), track.duration)
    }
}
