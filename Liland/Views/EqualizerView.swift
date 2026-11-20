import SwiftUI

/// The iPhone's Now Playing waveform: six thin bars in the album color that grow up and
/// down from the middle, from bass on the left to treble on the right (see
/// `SpectrumAnalyzer`). They follow the music's real sound when `live` is given, move on
/// their own otherwise, and settle into a row of dots when paused.
///
/// Proportions measured from the iPhone: the gap is about 0.65 of a bar's width, a full
/// bar about 10 widths tall, and an empty bar a dot as tall as it is wide.
struct EqualizerView: View {
    let isPlaying: Bool
    let color: Color
    var live: LiveLevels?

    private static let barCount = SpectrumAnalyzer.bandCount
    private static let gapRatio: CGFloat = 0.65
    /// Without live audio: each bar's usual height on the iPhone, and how it wobbles.
    private static let restingLevels: [Double] = [0.69, 0.2, 0.56, 0.74, 0.75, 0.63]
    private static let speeds: [Double] = [5.1, 6.7, 4.3, 7.9, 5.6, 6.1]
    private static let phases: [Double] = [0, 1.3, 2.6, 0.7, 2.1, 3.4]

    var body: some View {
        // Live levels are read on every screen refresh so the bars keep up with the beat.
        TimelineView(.animation(minimumInterval: live == nil ? 1 / 30 : nil, paused: !isPlaying)) { context in
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
        // On the iPhone, pausing shrinks the bars into dots over about half a second.
        .animation(.easeOut(duration: 0.5), value: isPlaying)
    }

    /// The bar's height between a dot (0) and full (1).
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
