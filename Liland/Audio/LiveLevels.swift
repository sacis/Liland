import Foundation
import os

/// `delay` holds the bars back by the rest of the trip to the ears (long on Bluetooth).
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
            if let stale = history.firstIndex(where: { $0.time >= now - delay - 0.25 }), stale > 0 {
                history.removeFirst(stale)
            }
        }
    }
}
