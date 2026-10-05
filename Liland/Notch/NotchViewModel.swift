import Foundation
import Observation

@Observable
final class NotchViewModel {
    enum Status { case closed, open }

    var status: Status = .closed
    var geometry: NotchGeometry
    let nowPlaying: NowPlayingController

    /// True while the user drags the progress bar, so the island doesn't close mid-drag.
    private(set) var isInteracting = false
    @ObservationIgnored var onInteractionEnded: (() -> Void)?

    init(geometry: NotchGeometry, nowPlaying: NowPlayingController) {
        self.geometry = geometry
        self.nowPlaying = nowPlaying
    }

    var mode: NotchMode {
        let hasTrack = nowPlaying.track != nil
        switch status {
        case .open:
            return hasTrack ? .open : .openMessage
        case .closed:
            return hasTrack && nowPlaying.isPlaying ? .compact : .idle
        }
    }

    func beginInteraction() {
        isInteracting = true
    }

    func endInteraction() {
        isInteracting = false
        onInteractionEnded?()
    }
}
