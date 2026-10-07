import SwiftUI

struct ExpandedPlayerView: View {
    let viewModel: NotchViewModel

    private var nowPlaying: NowPlayingController { viewModel.nowPlaying }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: viewModel.geometry.notchSize.height)

            VStack(spacing: 10) {
                trackInfo
                PlaybackProgressView(viewModel: viewModel)
                controls
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 14)
        }
    }

    private var header: some View {
        HStack {
            Text(nowPlaying.isPlaying ? "Now Playing" : "Paused")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            if let player = nowPlaying.activePlayer, let icon = player.icon {
                Button { player.open() } label: {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help(Text("Open \(player.displayName)"))
            }
        }
        .padding(.horizontal, 22)
    }

    private var trackInfo: some View {
        HStack(spacing: 12) {
            ArtworkView(image: nowPlaying.artwork, cornerRadius: 10)
                .frame(width: 56, height: 56)
                .onTapGesture { nowPlaying.activePlayer?.open() }

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: nowPlaying.track?.title ?? "")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(verbatim: nowPlaying.track?.artist ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(1)

            Spacer(minLength: 8)

            EqualizerView(isPlaying: nowPlaying.isPlaying, color: nowPlaying.accentColor, live: nowPlaying.audioLevels.live)
                .frame(width: 22, height: 18)
        }
    }

    private var controls: some View {
        HStack(spacing: 26) {
            modeButton(
                systemName: "shuffle",
                isOn: nowPlaying.isShuffling,
                help: "Shuffle",
                action: nowPlaying.toggleShuffle
            )
            ControlButton(systemName: "backward.fill", size: 18, help: "Previous", action: nowPlaying.previousTrack)
            ControlButton(
                systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                size: 26,
                help: nowPlaying.isPlaying ? "Pause" : "Play",
                action: nowPlaying.playPause
            )
            ControlButton(systemName: "forward.fill", size: 18, help: "Next", action: nowPlaying.nextTrack)
            modeButton(
                systemName: nowPlaying.repeatMode == .one ? "repeat.1" : "repeat",
                isOn: nowPlaying.repeatMode.map { $0 != .off },
                help: "Repeat",
                action: nowPlaying.cycleRepeat
            )
        }
        .frame(height: 30)
    }

    /// Lit in the artwork's color when on. Kept in place but invisible when the player
    /// doesn't report it (`isOn` nil), so the main controls stay centered.
    private func modeButton(
        systemName: String,
        isOn: Bool?,
        help: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        ControlButton(
            systemName: systemName,
            size: 14,
            help: help,
            color: isOn == true ? nowPlaying.accentColor : .white.opacity(0.5),
            action: action
        )
        .opacity(isOn == nil ? 0 : 1)
        .disabled(isOn == nil)
    }
}

private struct ControlButton: View {
    let systemName: String
    let size: CGFloat
    let help: LocalizedStringKey
    var color: Color = .white
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(color.opacity(isHovering ? 1 : 0.85))
                .frame(width: 40, height: 30)
                .background(
                    Circle()
                        .fill(.white.opacity(isHovering ? 0.12 : 0))
                        .frame(width: 38, height: 38)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .help(help)
    }
}

private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
