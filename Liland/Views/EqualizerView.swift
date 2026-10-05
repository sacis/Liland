import SwiftUI

/// Four bouncing bars tinted with the album color. Freezes low when paused.
struct EqualizerView: View {
    let isPlaying: Bool
    let color: Color

    private static let speeds: [Double] = [5.1, 6.7, 4.3, 7.9]
    private static let phases: [Double] = [0, 1.3, 2.6, 0.7]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !isPlaying)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                HStack(spacing: proxy.size.width * 0.12) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule()
                            .fill(color)
                            .frame(height: proxy.size.height * level(index, time: time))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: isPlaying)
    }

    private func level(_ index: Int, time: Double) -> CGFloat {
        guard isPlaying else { return 0.25 }
        let fast = abs(sin(time * Self.speeds[index] + Self.phases[index]))
        let slow = abs(sin(time * Self.speeds[index] * 0.53 + Self.phases[index] * 2))
        return 0.25 + 0.75 * (fast * 0.6 + slow * 0.4)
    }
}
