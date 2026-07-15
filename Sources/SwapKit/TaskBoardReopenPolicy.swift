public enum TaskBoardReopenPolicy {
    public static func shouldShowBoard(hasVisibleWindows: Bool) -> Bool {
        !hasVisibleWindows
    }
}
