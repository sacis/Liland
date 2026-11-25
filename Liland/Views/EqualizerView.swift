import SwiftUI

struct EqualizerView: View {
    let isPlaying: Bool
    let color: Color
    var live: LiveLevels?

    private static let barCount = SpectrumAnalyzer.bandCount
    private static let gapRatio: CGFloat = 0.65
    private static let restingLevels: [Double] = [0.69, 0.2, 0.56, 0.74, 0.75, 0.63]
    private static let speeds: [Double] = [5.1, 6.7, 4.3, 7.9, 5.6, 6.1]
    private static let phases: [Double] = [0, 1.3, 2.6, 0.7, 2.1, 3.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: live == nil ? 1 / 30 : 1 / 60, paused: !isPlaying)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let levels = live?.current
            GeometryReader { proxy in
                let count = CGFloat(Self.barCount)
                let barWidth = proxy.size.width / (count + (count - 1) * Self.gapRatio)
                HStack(spacing: barWidth * Self.gapRatio) {
                    ForEach(0..<Self.barCount, id: \.self) { index in
                        let level = level(index, time: time, levels: levels)
                        Capsule()
                            .fill(color)
                            .frame(width: barWidth, height: barWidth + (proxy.size.height - barWidth) * level)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.easeOut(duration: 0.5), value: isPlaying)
    }

    private func level(_ index: Int, time: Double, levels: [Double]?) -> CGFloat {
        guard isPlaying else { return 0 }
        if let levels, levels.indices.contains(index) {
            return levels[index]
        }
        let fast = sin(time * Self.speeds[index] + Self.phases[index])
        let slow = sin(time * Self.speeds[index] * 0.53 + Self.phases[index] * 2)
        return min(max(Self.restingLevels[index] + 0.22 * (fast * 0.6 + slow * 0.4), 0), 1)
    }
}
