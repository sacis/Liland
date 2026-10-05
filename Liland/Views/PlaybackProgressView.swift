import SwiftUI

/// Elapsed time, a draggable progress bar and remaining time.
struct PlaybackProgressView: View {
    let viewModel: NotchViewModel

    @State private var dragFraction: Double?

    private var nowPlaying: NowPlayingController { viewModel.nowPlaying }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let duration = nowPlaying.track?.duration ?? 0
            let position = dragFraction.map { $0 * duration } ?? nowPlaying.currentPosition(at: context.date)

            HStack(spacing: 8) {
                timeLabel(Self.format(position))
                if duration > 0 {
                    bar(fraction: position / duration, duration: duration)
                    timeLabel("-" + Self.format(duration - position))
                } else {
                    // Live streams, such as radio stations, have no length to seek in.
                    Capsule().fill(.white.opacity(0.18)).frame(height: 4)
                    Text("Live")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(minWidth: 36)
                }
            }
        }
        .frame(height: 14)
    }

    private func bar(fraction: Double, duration: TimeInterval) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule()
                    .fill(.white)
                    .frame(width: width * min(max(fraction, 0), 1))
            }
            .frame(height: dragFraction == nil ? 4 : 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragFraction == nil { viewModel.beginInteraction() }
                        dragFraction = Self.clamp(value.location.x / width)
                    }
                    .onEnded { value in
                        nowPlaying.seek(to: Self.clamp(value.location.x / width) * duration)
                        dragFraction = nil
                        viewModel.endInteraction()
                    }
            )
            .animation(.easeOut(duration: 0.15), value: dragFraction == nil)
        }
    }

    private func timeLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
            .frame(minWidth: 36)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
