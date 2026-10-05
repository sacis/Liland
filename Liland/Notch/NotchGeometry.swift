import AppKit

/// What the island is currently showing. Each mode has its own size and corner radii.
enum NotchMode: Equatable {
    /// Nothing playing: blends into the hardware notch.
    case idle
    /// Music playing: the notch grows sideways with artwork and an equalizer.
    case compact
    /// Hovered with a track: full player.
    case open
    /// Hovered without a track (Spotify closed, nothing playing, no permission).
    case openMessage

    var isOpen: Bool { self == .open || self == .openMessage }

    var cornerRadii: (top: CGFloat, bottom: CGFloat) {
        switch self {
        case .idle: (6, 10)
        case .compact: (6, 12)
        case .open: (18, 28)
        case .openMessage: (16, 24)
        }
    }
}

struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchSize: CGSize
    var hasNotch: Bool

    static let compactWing: CGFloat = 42
    static let openWidth: CGFloat = 480
    static let openContentHeight: CGFloat = 140
    static let messageContentHeight: CGFloat = 70
    /// The panel is fixed at this size; the island animates inside it.
    static let windowSize = CGSize(width: 640, height: 260)

    static func current() -> NotchGeometry {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else {
            return NotchGeometry(
                screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                notchSize: CGSize(width: 190, height: 24),
                hasNotch: false
            )
        }
        return NotchGeometry(screen: screen)
    }

    func size(for mode: NotchMode) -> CGSize {
        switch mode {
        case .idle:
            notchSize
        case .compact:
            CGSize(width: notchSize.width + Self.compactWing * 2, height: notchSize.height)
        case .open:
            CGSize(width: Self.openWidth, height: notchSize.height + Self.openContentHeight)
        case .openMessage:
            CGSize(width: Self.openWidth, height: notchSize.height + Self.messageContentHeight)
        }
    }

    /// The island's rect in global screen coordinates (origin bottom-left).
    func screenRect(for mode: NotchMode) -> CGRect {
        let size = size(for: mode)
        return CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    var windowFrame: CGRect {
        let size = Self.windowSize
        return CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}

extension NotchGeometry {
    init(screen: NSScreen) {
        screenFrame = screen.frame
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchSize = CGSize(width: screen.frame.width - left.width - right.width, height: top)
            hasNotch = true
        } else {
            let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
            notchSize = CGSize(width: 190, height: max(menuBarHeight, 24))
            hasNotch = false
        }
    }
}
