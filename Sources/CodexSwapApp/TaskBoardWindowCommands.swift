import Foundation

@MainActor
final class TaskBoardWindowCommands {
    weak var controller: TaskBoardWindowController?

    func toggleFullScreen() {
        controller?.toggleFullScreen()
    }

    func moveToNextDisplay() {
        controller?.moveToNextDisplay()
    }

    func centerOnCurrentDisplay() {
        controller?.centerOnCurrentDisplay()
    }
}
