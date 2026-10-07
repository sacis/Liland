import SwiftUI

/// Four bars tinted with the album color. They follow the music's real sound when
/// `live` is given, bounce on their own otherwise, and freeze low when paused.
struct EqualizerView: View {
    let isPlaying: Bool
    let color: Color
    var live: LiveLevels?

    private static let speeds: [Double] = [5.1, 6.7, 4.3, 7.9]
    private static let phases: [Double] = [0, 1.3, 2.6, 0.7]

    var body: some View {
        // Live levels are read on every screen refresh so the bars keep up with the beat.
        TimelineView(.animation(minimumInterval: live == nil ? 1 / 24 : nil, paused: !isPlaying)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let levels = live?.current
            GeometryReader { proxy in
                HStack(spacing: proxy.size.width * 0.12) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule()
                            .fill(color)
                            .frame(height: proxy.size.height * level(index, time: time, levels: levels))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: isPlaying)
    }

    private func level(_ index: Int, time: Double, levels: [Double]?) -> CGFloat {
        guard isPlaying else { return 0.25 }
        if let levels, levels.indices.contains(index) {
            return 0.2 + 0.8 * levels[index]
        }
        let fast = abs(sin(time * Self.speeds[index] + Self.phases[index]))
        let slow = abs(sin(time * Self.speeds[index] * 0.53 + Self.phases[index] * 2))
        return 0.25 + 0.75 * (fast * 0.6 + slow * 0.4)
    }
}
