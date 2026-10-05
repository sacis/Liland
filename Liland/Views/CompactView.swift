import SwiftUI

/// The "Live Activity" look: artwork on the left of the camera, equalizer on the right.
struct CompactView: View {
    let nowPlaying: NowPlayingController
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ArtworkView(image: nowPlaying.artwork, cornerRadius: 5)
                .frame(width: 20, height: 20)
            Spacer(minLength: notchWidth)
            EqualizerView(isPlaying: nowPlaying.isPlaying, color: nowPlaying.accentColor)
                .frame(width: 18, height: 13)
        }
        .padding(.horizontal, 10)
    }
}
