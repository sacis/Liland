import AppKit
import SwiftUI

/// Owns the notch panel and decides when the island opens and closes.
///
/// The panel ignores the mouse except when the pointer is over the open island,
/// so clicks around the notch keep reaching the menu bar and other apps.
/// Hover is detected from global/local mouse monitors instead of SwiftUI hover,
/// because a panel that ignores mouse events never receives hover.
final class NotchWindowController {
    private let viewModel: NotchViewModel
    private let panel = NotchPanel()
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?

    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var peekWork: DispatchWorkItem?
    private var isPeeking = false

    private static let openDelay: TimeInterval = 0.1
    private static let closeDelay: TimeInterval = 0.15
    private static let peekDuration: TimeInterval = 3.5

    init(nowPlaying: NowPlayingController) {
        viewModel = NotchViewModel(geometry: .current(), nowPlaying: nowPlaying)

        let hostingView = NotchHostingView(rootView: NotchRootView(viewModel: viewModel))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.setFrame(viewModel.geometry.windowFrame, display: false)

        viewModel.onInteractionEnded = { [weak self] in self?.handleMouse() }
        nowPlaying.onTrackChange = { [weak self] in self?.peek() }

        installMouseMonitors()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screenParametersChanged()
        }
    }

    deinit {
        monitors.forEach(NSEvent.removeMonitor)
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func show() {
        panel.orderFrontRegardless()
    }

    // MARK: - Mouse

    private func installMouseMonitors() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            self?.handleMouse()
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.handleMouse()
            return event
        }) {
            monitors.append(local)
        }
    }

    private func handleMouse() {
        let location = NSEvent.mouseLocation
        let geometry = viewModel.geometry
        let mode = viewModel.mode

        switch viewModel.status {
        case .closed:
            panel.ignoresMouseEvents = true
            let hotZone = geometry.screenRect(for: mode).insetBy(dx: -4, dy: -4)
            if hotZone.contains(location) {
                scheduleOpen()
            } else {
                cancelOpen()
            }

        case .open:
            let islandRect = geometry.screenRect(for: mode)
            if !viewModel.isInteracting {
                panel.ignoresMouseEvents = !islandRect.insetBy(dx: 0, dy: -4).contains(location)
            }
            if islandRect.insetBy(dx: -10, dy: -10).contains(location) {
                cancelClose()
                endPeek()
            } else if !viewModel.isInteracting && !isPeeking {
                scheduleClose()
            }
        }
    }

    private func scheduleOpen() {
        guard openWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.openWork = nil
            self?.open()
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.openDelay, execute: work)
    }

    private func cancelOpen() {
        openWork?.cancel()
        openWork = nil
    }

    private func scheduleClose() {
        guard closeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.closeWork = nil
            self?.close()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDelay, execute: work)
    }

    private func cancelClose() {
        closeWork?.cancel()
        closeWork = nil
    }

    // MARK: - State

    private func open() {
        cancelClose()
        guard viewModel.status == .closed else { return }
        viewModel.status = .open
        viewModel.nowPlaying.refresh()
        handleMouse()
    }

    private func close() {
        cancelOpen()
        endPeek()
        viewModel.status = .closed
        panel.ignoresMouseEvents = true
    }

    /// Briefly shows the full player when the song changes, like a Live Activity alert.
    private func peek() {
        guard Preferences.shouldPeekOnTrackChange, viewModel.status == .closed else { return }
        isPeeking = true
        open()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPeeking else { return }
            self.isPeeking = false
            self.handleMouse()
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekDuration, execute: work)
    }

    private func endPeek() {
        isPeeking = false
        peekWork?.cancel()
        peekWork = nil
    }

    private func screenParametersChanged() {
        viewModel.geometry = .current()
        panel.setFrame(viewModel.geometry.windowFrame, display: true)
    }
}
