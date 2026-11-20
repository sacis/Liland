import SwiftUI

/// Two decks side by side: tapping a cover opens that side's Spotify to pick its song; the middle swaps
/// whose voice is heard over whose instrumental.
struct DJView: View {
    let viewModel: NotchViewModel

    private var dj: DJController { viewModel.nowPlaying.dj }
    private static let accent = NowPlayingController.defaultAccent

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: viewModel.geometry.notchSize.height)
            Group {
                switch dj.step {
                case .needsAudioAccess:
                    permissionRow("Allow audio access to mix the songs", action: AudioCapturePermission.openSettings)
                case .starting, .off:
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Opening a second Spotify…")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready, .choosing, .preparing:
                    decks
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private var header: some View {
        HStack {
            Text("DJ Mode")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Button(action: dj.exit) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Exit DJ Mode")
        }
        .padding(.horizontal, 22)
    }

    // MARK: - Decks

    private var decks: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                DeckColumn(dj: dj, side: .left, accent: Self.accent)
                middle
                DeckColumn(dj: dj, side: .right, accent: Self.accent)
            }
            footer
                .frame(height: 26)
        }
        .padding(.top, 6)
    }

    private var middle: some View {
        VStack(spacing: 10) {
            syncBadge
                .frame(height: 16)
            Button(action: dj.swap) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(Self.accent))
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .help("Swap")
            Button(action: dj.playPause) {
                Image(systemName: dj.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(.white.opacity(dj.step == .ready ? 0.9 : 0.3))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.white.opacity(0.1)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .disabled(dj.step != .ready)
            .help(dj.isPlaying ? "Pause" : "Play")
        }
        .frame(width: 76)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var syncBadge: some View {
        switch dj.sync {
        case .idle:
            Color.clear
        case .listening:
            Text("Listening…")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        case .locked:
            HStack(spacing: 3) {
                Image(systemName: "metronome.fill")
                    .font(.system(size: 9))
                Text(verbatim: dj.tempo.map { String(format: "%.0f", $0) } ?? "")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(Self.accent)
            .help("In Sync")
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        switch dj.step {
        case .choosing(let side):
            HStack(spacing: 8) {
                hint(side == .left
                    ? "Play a song in the Spotify window on the left"
                    : "Play a song in the window on the right. The first time, log in to Spotify there.")
                Spacer(minLength: 4)
                smallButton("Cancel", action: dj.cancelChoosing)
            }
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                hint("Downloading it to play alongside…")
                Spacer(minLength: 0)
            }
        default:
            if dj.notice == .needsAccessibility {
                HStack(spacing: 8) {
                    hint("Allow Liland in Accessibility to control the two Spotify windows")
                    Spacer(minLength: 4)
                    smallButton("Settings", action: Accessibility.openSettings)
                }
            } else if let notice = dj.notice {
                hint(notice == .downloadFailed ? "Couldn't download that song. Try another one." : "Couldn't open a second Spotify.")
            } else if dj.decks.allSatisfy({ $0.track == nil }) || dj.decks.contains(where: { $0.track == nil }) {
                hint("Tap a cover to pick that side's song")
            } else if dj.sync == .locked {
                HStack(spacing: 6) {
                    Spacer()
                    smallIconButton("chevron.left", help: "One Beat Earlier") { dj.nudge(-1) }
                    Text("Beat")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                    smallIconButton("chevron.right", help: "One Beat Later") { dj.nudge(1) }
                    Spacer()
                }
            }
        }
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func smallButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Capsule().fill(.white.opacity(0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func smallIconButton(_ systemName: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func permissionRow(_ text: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "dial.medium")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white.opacity(0.1)))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(3)
            Spacer(minLength: 8)
            smallButton("Settings", action: action)
        }
        .frame(maxHeight: .infinity)
    }
}

private struct DeckColumn: View {
    let dj: DJController
    let side: DJController.Side
    let accent: Color

    private var deck: DJController.Deck { dj.decks[side.rawValue] }
    private var isChoosing: Bool { dj.step == .choosing(side) || dj.step == .preparing(side) }

    var body: some View {
        VStack(spacing: 6) {
            Button { dj.choose(side) } label: {
                ArtworkView(image: deck.artwork, cornerRadius: 10)
                    .frame(width: 64, height: 64)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(accent, lineWidth: isChoosing ? 2 : 0)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(.white))
                            .offset(x: 5, y: 5)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(dj.step != .ready)
            .help("Choose a Song")

            VStack(spacing: 1) {
                Text(verbatim: deck.track?.title ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(verbatim: deck.track?.artist ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .lineLimit(1)
            .frame(height: 30)

            Text(verbatim: details)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .frame(height: 12)

            rolePicker
        }
        .frame(maxWidth: .infinity)
    }

    /// "119 BPM · A♭m", plus the key move when it's shifted to suit the other song.
    private var details: String {
        var parts: [String] = []
        if let bpm = deck.bpm { parts.append(String(format: "%.0f BPM", bpm)) }
        if let key = deck.key { parts.append(key) }
        if deck.shift != 0 { parts.append(deck.shift > 0 ? "+\(deck.shift)" : "−\(-deck.shift)") }
        return parts.joined(separator: " · ")
    }

    private var rolePicker: some View {
        HStack(spacing: 2) {
            ForEach(DJController.Role.allCases, id: \.self) { role in
                Button { dj.setRole(role, for: side) } label: {
                    Text(Self.title(of: role))
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(deck.role == role ? .black : .white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background(Capsule().fill(deck.role == role ? .white.opacity(0.9) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.1)))
        .animation(.easeOut(duration: 0.15), value: deck.role)
    }

    private static func title(of role: DJController.Role) -> LocalizedStringKey {
        switch role {
        case .vocals: "Vocals"
        case .instrumental: "Instrumental"
        case .everything: "Full Mix"
        }
    }
}

/// Closed: each deck's cover in its wing of the notch.
struct DJCompactView: View {
    let dj: DJController
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ArtworkView(image: dj.decks[0].artwork, cornerRadius: 5)
                .frame(width: 20, height: 20)
            Spacer(minLength: notchWidth)
            ArtworkView(image: dj.decks[1].artwork, cornerRadius: 5)
                .frame(width: 20, height: 20)
        }
        .padding(.horizontal, 10)
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
