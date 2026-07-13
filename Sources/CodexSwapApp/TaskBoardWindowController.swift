import AppKit
import SwiftUI

@MainActor
final class TaskBoardWindowController: NSWindowController, NSWindowDelegate {
    init(viewModel: TaskBoardViewModel) {
        let hostingController = NSHostingController(rootView: TaskBoardView(model: viewModel))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "CodexSwap Task Board"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 1_080, height: 680))
        window.minSize = NSSize(width: 1_000, height: 620)
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
