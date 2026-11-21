import Foundation
import Observation

@Observable
final class NotchViewModel {
    enum Status { case closed, open }

    var status: Status = .closed
    var geometry: NotchGeometry
    let nowPlaying: NowPlayingController
    let outputs = OutputDevices()
    var showsDevices = false
    @ObservationIgnored private(set) var closeGraceUntil = Date.distantPast

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
            guard hasTrack else { return .openMessage }
            if showsDevices { return .openDevices(rows: outputs.rows) }
            return nowPlaying.audioLevels.isSupported && nowPlaying.audioLevels.isAdvanced ? .openAdvanced : .open
        case .closed:
            return hasTrack && nowPlaying.isPlaying ? .compact : .idle
        }
    }

    func showDevices() {
        outputs.load(for: nowPlaying.activePlayer)
        showsDevices = true
        closeGraceUntil = Date().addingTimeInterval(2)
    }

    func endCloseGrace() {
        closeGraceUntil = .distantPast
    }

    func beginInteraction() {
        isInteracting = true
    }

    func endInteraction() {
        isInteracting = false
        onInteractionEnded?()
    }
}
