import AppKit
import SwapKit

@MainActor
final class TaskBoardWindowFrameMonitor {
    private weak var window: NSWindow?
    private let autosaveName: String
    private var normalizationTask: Task<Void, Never>?
    private var isFullScreenTransitioning = false

    init(autosaveName: String) {
        self.autosaveName = autosaveName
    }

    func attach(to window: NSWindow) {
        self.window = window
    }

    func scheduleNormalization() {
        normalizationTask?.cancel()
        guard !isFullScreenTransitioning,
              let window,
              !window.styleMask.contains(.fullScreen) else { return }
        normalizationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.normalize(display: true)
        }
    }

    func normalizeImmediately(display: Bool) {
        normalizationTask?.cancel()
        normalize(display: display)
    }

    func cancel() {
        normalizationTask?.cancel()
        normalizationTask = nil
    }

    func beginFullScreenTransition() {
        isFullScreenTransitioning = true
        cancel()
    }

    func endFullScreenTransition() {
        isFullScreenTransitioning = false
    }

    private func normalize(display: Bool) {
        guard !isFullScreenTransitioning, let window else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        let fallbackScreen = NSScreen.main ?? screens[0]
        let fallbackIndex = screens.firstIndex(where: { $0 === fallbackScreen }) ?? 0
        let targetScreen = window.screen ?? fallbackScreen
        let sizing = TaskBoardWindowSizing.resolve(
            visibleWidth: targetScreen.visibleFrame.width,
            visibleHeight: targetScreen.visibleFrame.height
        )
        let current = Self.frame(from: window.frame)
        let recovered = TaskBoardWindowPlacement.recover(
            frame: current,
            visibleFrames: screens.map { Self.frame(from: $0.visibleFrame) },
            fallbackIndex: fallbackIndex,
            minimumWidth: sizing.minimumWidth,
            minimumHeight: sizing.minimumHeight
        )

        Self.applyMinimumSize(sizing, to: window)
        let isInteracting = window.inLiveResize || NSEvent.pressedMouseButtons != 0
        let shouldApply = TaskBoardWindowNormalization.shouldApply(
            current: current,
            recovered: recovered,
            isFullScreen: window.styleMask.contains(.fullScreen),
            isFullScreenTransitioning: isFullScreenTransitioning,
            isInteracting: isInteracting
        )
        if isInteracting, current != recovered {
            scheduleNormalization()
            return
        }
        guard shouldApply else { return }

        window.setFrame(Self.rect(from: recovered), display: display)
        window.saveFrame(usingName: autosaveName)
    }

    static func applyMinimumSize(_ sizing: TaskBoardWindowSizing, to window: NSWindow) {
        let frameSize = NSSize(width: sizing.minimumWidth, height: sizing.minimumHeight)
        window.minSize = frameSize
        window.contentMinSize = window.contentRect(
            forFrameRect: NSRect(origin: .zero, size: frameSize)
        ).size
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
