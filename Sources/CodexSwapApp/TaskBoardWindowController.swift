import AppKit
import SwiftUI
import SwapKit

@MainActor
final class TaskBoardWindowController: NSWindowController, NSWindowDelegate {
    enum PendingPlacement {
        case moveToNextDisplay
        case centerOnCurrentDisplay
    }

    private static let frameAutosaveName = "CodexSwapTaskBoardWindow"

    var pendingPlacement: PendingPlacement?
    let frameMonitor: TaskBoardWindowFrameMonitor

    init(viewModel: TaskBoardViewModel) {
        frameMonitor = TaskBoardWindowFrameMonitor(autosaveName: Self.frameAutosaveName)
        let windowCommands = TaskBoardWindowCommands()
        let hostingController = NSHostingController(
            rootView: TaskBoardView(model: viewModel, windowCommands: windowCommands)
        )
        let window = NSWindow(contentViewController: hostingController)
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let sizing = TaskBoardWindowSizing.resolve(
            visibleWidth: visible.width,
            visibleHeight: visible.height
        )
        window.title = "CodexSwap Task Board"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.setContentSize(NSSize(width: sizing.initialWidth, height: sizing.initialHeight))
        TaskBoardWindowFrameMonitor.applyMinimumSize(sizing, to: window)
        window.isReleasedWhenClosed = false
        window.center()
        _ = window.setFrameAutosaveName(Self.frameAutosaveName)
        frameMonitor.attach(to: window)
        frameMonitor.normalizeImmediately(display: false)
        super.init(window: window)
        window.delegate = self
        windowCommands.controller = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        frameMonitor.scheduleNormalization(reason: "show")
    }

    func toggleFullScreen() {
        pendingPlacement = nil
        window?.toggleFullScreen(nil)
    }

    func moveToNextDisplay() {
        performAfterLeavingFullScreen(.moveToNextDisplay)
    }

    func centerOnCurrentDisplay() {
        performAfterLeavingFullScreen(.centerOnCurrentDisplay)
    }

    private func performAfterLeavingFullScreen(_ placement: PendingPlacement) {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) {
            pendingPlacement = placement
            window.toggleFullScreen(nil)
        } else {
            perform(placement)
        }
    }

    func perform(_ placement: PendingPlacement) {
        switch placement {
        case .moveToNextDisplay:
            moveWindowToNextDisplay()
        case .centerOnCurrentDisplay:
            centerWindowOnCurrentDisplay()
        }
    }

    private func moveWindowToNextDisplay() {
        guard let window else { return }
        let screens = NSScreen.screens
        guard screens.count > 1 else { return }

        let source = window.screen ?? NSScreen.main ?? screens[0]
        let currentIndex = screens.firstIndex(where: { $0 === source }) ?? 0
        guard let targetIndex = TaskBoardWindowPlacement.nextDisplayIndex(
            currentIndex: currentIndex,
            displayCount: screens.count
        ) else { return }

        let target = screens[targetIndex]
        let sizing = TaskBoardWindowSizing.resolve(
            visibleWidth: target.visibleFrame.width,
            visibleHeight: target.visibleFrame.height
        )
        let moved = TaskBoardWindowPlacement.move(
            frame: Self.frame(from: window.frame),
            from: Self.frame(from: source.visibleFrame),
            to: Self.frame(from: target.visibleFrame),
            minimumWidth: sizing.minimumWidth,
            minimumHeight: sizing.minimumHeight
        )
        apply(moved, sizing: sizing, to: window, animated: true)
    }

    private func centerWindowOnCurrentDisplay() {
        guard let window else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let sizing = TaskBoardWindowSizing.resolve(
            visibleWidth: screen.visibleFrame.width,
            visibleHeight: screen.visibleFrame.height
        )
        let centered = TaskBoardWindowPlacement.center(
            frame: Self.frame(from: window.frame),
            in: Self.frame(from: screen.visibleFrame),
            minimumWidth: sizing.minimumWidth,
            minimumHeight: sizing.minimumHeight
        )
        apply(centered, sizing: sizing, to: window, animated: true)
    }

    private func apply(
        _ frame: TaskBoardWindowFrame,
        sizing: TaskBoardWindowSizing,
        to window: NSWindow,
        animated: Bool
    ) {
        TaskBoardWindowFrameMonitor.applyMinimumSize(sizing, to: window)
        window.setFrame(Self.rect(from: frame), display: true, animate: animated)
        window.saveFrame(usingName: Self.frameAutosaveName)
        window.makeKeyAndOrderFront(nil)
    }

    private static func frame(from rect: NSRect) -> TaskBoardWindowFrame {
        TaskBoardWindowFrame(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.width,
            height: rect.height
        )
    }

    private static func rect(from frame: TaskBoardWindowFrame) -> NSRect {
        NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }
}
