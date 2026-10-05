import SwiftUI

/// Shown when the island is hovered but there is no track to display.
struct MessageView: View {
    let nowPlaying: NowPlayingController
    let notchHeight: CGFloat

    private struct Content {
        let icon: String
        let title: String
        let subtitle: String
        let actionTitle: String?
        let action: () -> Void
    }

    private var content: Content {
        if let player = nowPlaying.deniedPlayer {
            return Content(
                icon: "lock",
                title: String(localized: "No access to \(player.displayName)"),
                subtitle: String(localized: "Allow Liland in Privacy & Security › Automation"),
                actionTitle: String(localized: "Settings"),
                action: Self.openAutomationSettings
            )
        }
        let player = nowPlaying.preferredPlayer
        return Content(
            icon: "music.note",
            title: String(localized: "Nothing playing"),
            subtitle: String(localized: "Play something in Spotify or Apple Music"),
            actionTitle: player.map { String(localized: "Open \($0.displayName)") },
            action: { player?.open() }
        )
    }

    var body: some View {
        let content = content
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)

            HStack(spacing: 12) {
                Image(systemName: content.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.white.opacity(0.1)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: content.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(verbatim: content.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)

                Spacer(minLength: 8)

                if let actionTitle = content.actionTitle {
                    Button(action: content.action) {
                        Text(verbatim: actionTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(.white.opacity(0.16)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 22)
            .frame(maxHeight: .infinity)
            .padding(.bottom, 6)
        }
    }

    private static func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }
}
