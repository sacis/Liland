import Foundation
import os

/// The bar levels over the last moments: written by the audio queue as soon as they're
/// computed, and read by the equalizer on every screen refresh.
///
/// Liland hears the music before it leaves the speakers or headphones. `delay` holds
/// the bars back by the rest of that trip (long on Bluetooth) so they land on the beat.
final class LiveLevels: Sendable {
    private struct Entry {
        let time: TimeInterval
        let levels: [Double]
    }

    let delay: TimeInterval
    private let history = OSAllocatedUnfairLock(initialState: [Entry]())

    init(delay: TimeInterval) {
        self.delay = delay
    }

    /// The levels of what the user is hearing right now.
    var current: [Double] {
        let target = ProcessInfo.processInfo.systemUptime - delay
        return history.withLock { history in
            history.last { $0.time <= target }?.levels
        } ?? [Double](repeating: 0, count: SpectrumAnalyzer.bandCount)
    }

    func update(_ levels: [Double]) {
        let now = ProcessInfo.processInfo.systemUptime
        history.withLock { history in
            history.append(Entry(time: now, levels: levels))
            // Keep just enough to cover the delay, plus a little margin.
            if let stale = history.firstIndex(where: { $0.time >= now - delay - 0.25 }), stale > 0 {
                history.removeFirst(stale)
            }
        }
    }
}
