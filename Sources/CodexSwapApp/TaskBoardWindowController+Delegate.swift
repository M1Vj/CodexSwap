import AppKit

extension TaskBoardWindowController {
    func windowDidExitFullScreen(_ notification: Notification) {
        frameMonitor.endFullScreenTransition()
        if let pendingPlacement {
            self.pendingPlacement = nil
            perform(pendingPlacement)
        }
        frameMonitor.scheduleNormalization()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        pendingPlacement = nil
        frameMonitor.endFullScreenTransition()
        frameMonitor.scheduleNormalization()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        frameMonitor.beginFullScreenTransition()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        frameMonitor.endFullScreenTransition()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        frameMonitor.endFullScreenTransition()
        frameMonitor.scheduleNormalization()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        frameMonitor.beginFullScreenTransition()
    }

    func windowDidMove(_ notification: Notification) {
        frameMonitor.scheduleNormalization()
    }

    func windowDidResize(_ notification: Notification) {
        frameMonitor.scheduleNormalization()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        frameMonitor.scheduleNormalization()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        frameMonitor.scheduleNormalization()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        frameMonitor.scheduleNormalization()
    }

    func windowWillClose(_ notification: Notification) {
        frameMonitor.cancel()
    }
}
