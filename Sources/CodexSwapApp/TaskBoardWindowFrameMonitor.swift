import AppKit
import OSLog
import SwapKit

@MainActor
final class TaskBoardWindowFrameMonitor {
    private weak var window: NSWindow?
    private let autosaveName: String
    private let correlationID = UUID().uuidString
    private let logger = Logger(subsystem: "com.codexswap.app", category: "TaskBoardWindow")
    private var normalizationTask: Task<Void, Never>?
    private var isFullScreenTransitioning = false

    init(autosaveName: String) {
        self.autosaveName = autosaveName
    }

    func attach(to window: NSWindow) {
        self.window = window
        record(event: "attached")
    }

    func scheduleNormalization(reason: String = "unspecified") {
        normalizationTask?.cancel()
        guard !isFullScreenTransitioning,
              let window,
              !window.styleMask.contains(.fullScreen) else { return }
        record(event: "normalization_scheduled", detail: reason, level: .debug)
        normalizationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.normalize(display: true, reason: reason)
        }
    }

    func normalizeImmediately(display: Bool) {
        normalizationTask?.cancel()
        normalize(display: display, reason: "immediate")
    }

    func cancel() {
        normalizationTask?.cancel()
        normalizationTask = nil
    }

    func beginFullScreenTransition() {
        isFullScreenTransitioning = true
        cancel()
        record(event: "full_screen_transition_began")
    }

    func endFullScreenTransition() {
        isFullScreenTransitioning = false
        record(event: "full_screen_transition_ended")
    }

    func record(event: String, detail: String = "", level: OSLogType = .info) {
        guard let window else { return }
        let frame = window.frame
        let screenFrame = window.screen?.visibleFrame ?? .zero
        logger.log(
            level: level,
            "event=\(event, privacy: .public) correlation_id=\(self.correlationID, privacy: .public) detail=\(detail, privacy: .public) frame_x=\(frame.origin.x, privacy: .public) frame_y=\(frame.origin.y, privacy: .public) frame_width=\(frame.width, privacy: .public) frame_height=\(frame.height, privacy: .public) screen_x=\(screenFrame.origin.x, privacy: .public) screen_y=\(screenFrame.origin.y, privacy: .public) screen_width=\(screenFrame.width, privacy: .public) screen_height=\(screenFrame.height, privacy: .public) full_screen=\(window.styleMask.contains(.fullScreen), privacy: .public) occluded=\(!window.occlusionState.contains(.visible), privacy: .public)"
        )
    }

    private func normalize(display: Bool, reason: String) {
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
            record(event: "normalization_deferred", detail: reason, level: .debug)
            scheduleNormalization(reason: reason)
            return
        }
        guard shouldApply else {
            record(event: "normalization_not_needed", detail: reason, level: .debug)
            return
        }

        record(event: "normalization_applied", detail: reason)
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
