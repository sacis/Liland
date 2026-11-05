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

enum RepeatMode: Equatable {
    case off
    case all
    case one
}

struct PlayerSnapshot: Equatable {
    var track: NowPlayingTrack
    var isPlaying: Bool
    var position: TimeInterval
    var positionDate: Date
    var isShuffling: Bool?
    var repeatMode: RepeatMode?

    func elapsed(at date: Date) -> TimeInterval {
        let value = position + (isPlaying ? date.timeIntervalSince(positionDate) : 0)
        guard track.duration > 0 else { return max(value, 0) }
        return min(max(value, 0), track.duration)
    }
}
