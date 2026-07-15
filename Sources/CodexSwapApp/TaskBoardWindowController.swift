import AppKit
import SwiftUI
import SwapKit

@MainActor
final class TaskBoardWindowController: NSWindowController, NSWindowDelegate {
    init(viewModel: TaskBoardViewModel) {
        let hostingController = NSHostingController(rootView: TaskBoardView(model: viewModel))
        let window = NSWindow(contentViewController: hostingController)
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let sizing = TaskBoardWindowSizing.resolve(
            visibleWidth: visible.width,
            visibleHeight: visible.height
        )
        window.title = "CodexSwap Task Board"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: sizing.initialWidth, height: sizing.initialHeight))
        window.minSize = NSSize(width: sizing.minimumWidth, height: sizing.minimumHeight)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
