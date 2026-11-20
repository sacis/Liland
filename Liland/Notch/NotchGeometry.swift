import AppKit

enum NotchMode: Equatable {
    case idle
    case compact
    case open
    case openAdvanced
    case openMessage

    var isOpen: Bool { self != .idle && self != .compact }

    var cornerRadii: (top: CGFloat, bottom: CGFloat) {
        switch self {
        case .idle: (6, 10)
        case .compact: (6, 12)
        case .open, .openAdvanced: (18, 28)
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
    static let soundControlsHeight: CGFloat = 132
    static let messageContentHeight: CGFloat = 70
    static let windowSize = CGSize(width: 640, height: 400)

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
        case .openAdvanced:
            CGSize(width: Self.openWidth, height: notchSize.height + Self.openContentHeight + Self.soundControlsHeight)
        case .openMessage:
            CGSize(width: Self.openWidth, height: notchSize.height + Self.messageContentHeight)
        }
    }

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
