import SwiftUI

struct NotchRootView: View {
    let viewModel: NotchViewModel

    var body: some View {
        let mode = viewModel.mode
        let geometry = viewModel.geometry
        let size = geometry.size(for: mode)
        let radii = mode.cornerRadii

        ZStack(alignment: .top) {
            Color.black
            content(for: mode)
                .padding(.horizontal, radii.top)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(NotchShape(topRadius: radii.top, bottomRadius: radii.bottom))
        .shadow(color: .black.opacity(mode.isOpen ? 0.5 : 0), radius: 14, y: 6)
        // Without a hardware notch there is nothing to blend into, so hide when idle.
        .opacity(mode == .idle && !geometry.hasNotch ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: mode)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func content(for mode: NotchMode) -> some View {
        let notch = viewModel.geometry.notchSize
        switch mode {
        case .idle:
            EmptyView()
        case .compact:
            CompactView(nowPlaying: viewModel.nowPlaying, notchWidth: notch.width)
                .frame(height: notch.height)
                .transition(.opacity)
        case .open:
            ExpandedPlayerView(viewModel: viewModel)
                .frame(
                    width: NotchGeometry.openWidth - NotchMode.open.cornerRadii.top * 2,
                    height: notch.height + NotchGeometry.openContentHeight,
                    alignment: .top
                )
                .transition(.islandContent)
        case .openMessage:
            MessageView(nowPlaying: viewModel.nowPlaying, notchHeight: notch.height)
                .frame(
                    width: NotchGeometry.openWidth - NotchMode.openMessage.cornerRadii.top * 2,
                    height: notch.height + NotchGeometry.messageContentHeight,
                    alignment: .top
                )
                .transition(.islandContent)
        }
    }
}

private extension AnyTransition {
    static var islandContent: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.85, anchor: .top)).animation(.spring(response: 0.42, dampingFraction: 0.8).delay(0.05)),
            removal: .opacity.combined(with: .scale(scale: 0.85, anchor: .top)).animation(.easeOut(duration: 0.15))
        )
    }
}
