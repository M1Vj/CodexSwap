import AppKit

extension TaskBoardWindowController {
    func windowDidExitFullScreen(_ notification: Notification) {
        frameMonitor.endFullScreenTransition()
        if let pendingPlacement {
            self.pendingPlacement = nil
            perform(pendingPlacement)
        }
        frameMonitor.scheduleNormalization(reason: "did_exit_full_screen")
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        pendingPlacement = nil
        frameMonitor.endFullScreenTransition()
        frameMonitor.scheduleNormalization(reason: "failed_to_exit_full_screen")
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        frameMonitor.beginFullScreenTransition()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        frameMonitor.endFullScreenTransition()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        frameMonitor.endFullScreenTransition()
        frameMonitor.scheduleNormalization(reason: "failed_to_enter_full_screen")
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        frameMonitor.beginFullScreenTransition()
    }

    func windowDidMove(_ notification: Notification) {
        frameMonitor.record(event: "did_move", level: .debug)
        frameMonitor.scheduleNormalization(reason: "did_move")
    }

    func windowDidResize(_ notification: Notification) {
        frameMonitor.record(event: "did_resize", level: .debug)
        frameMonitor.scheduleNormalization(reason: "did_resize")
    }

    func windowDidChangeScreen(_ notification: Notification) {
        frameMonitor.record(event: "did_change_screen")
        frameMonitor.scheduleNormalization(reason: "did_change_screen")
    }

    func windowDidBecomeKey(_ notification: Notification) {
        frameMonitor.record(event: "did_become_key")
        frameMonitor.scheduleNormalization(reason: "did_become_key")
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        frameMonitor.record(event: "did_change_occlusion")
        frameMonitor.scheduleNormalization(reason: "did_change_occlusion")
    }

    func windowWillClose(_ notification: Notification) {
        frameMonitor.cancel()
    }
}
