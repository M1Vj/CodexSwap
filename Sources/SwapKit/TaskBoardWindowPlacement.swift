public struct TaskBoardWindowFrame: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public func contains(_ other: Self) -> Bool {
        other.x >= x
            && other.y >= y
            && other.x + other.width <= x + width
            && other.y + other.height <= y + height
    }

    fileprivate func intersectionArea(with other: Self) -> Double {
        let intersectionWidth = max(0, min(x + width, other.x + other.width) - max(x, other.x))
        let intersectionHeight = max(0, min(y + height, other.y + other.height) - max(y, other.y))
        return intersectionWidth * intersectionHeight
    }
}

public enum TaskBoardWindowPlacement {
    public static func move(
        frame: TaskBoardWindowFrame,
        from source: TaskBoardWindowFrame,
        to target: TaskBoardWindowFrame,
        minimumWidth: Double = 1,
        minimumHeight: Double = 1
    ) -> TaskBoardWindowFrame {
        let target = validVisibleFrame(target)
        let source = validVisibleFrame(source)
        let width = min(max(frame.width, minimumWidth, 1), target.width)
        let height = min(max(frame.height, minimumHeight, 1), target.height)
        let horizontalPosition = clamp((frame.midX - source.x) / source.width, lower: 0, upper: 1)
        let verticalPosition = clamp((frame.midY - source.y) / source.height, lower: 0, upper: 1)

        return TaskBoardWindowFrame(
            x: clamp(
                target.x + horizontalPosition * target.width - width / 2,
                lower: target.x,
                upper: target.x + target.width - width
            ),
            y: clamp(
                target.y + verticalPosition * target.height - height / 2,
                lower: target.y,
                upper: target.y + target.height - height
            ),
            width: width,
            height: height
        )
    }

    public static func center(
        frame: TaskBoardWindowFrame,
        in visibleFrame: TaskBoardWindowFrame,
        minimumWidth: Double = 1,
        minimumHeight: Double = 1
    ) -> TaskBoardWindowFrame {
        let visibleFrame = validVisibleFrame(visibleFrame)
        let width = min(max(frame.width, minimumWidth, 1), visibleFrame.width)
        let height = min(max(frame.height, minimumHeight, 1), visibleFrame.height)
        return TaskBoardWindowFrame(
            x: visibleFrame.x + (visibleFrame.width - width) / 2,
            y: visibleFrame.y + (visibleFrame.height - height) / 2,
            width: width,
            height: height
        )
    }

    public static func recover(
        frame: TaskBoardWindowFrame,
        visibleFrames: [TaskBoardWindowFrame],
        fallbackIndex: Int,
        minimumWidth: Double = 1,
        minimumHeight: Double = 1
    ) -> TaskBoardWindowFrame {
        guard !visibleFrames.isEmpty else {
            return TaskBoardWindowFrame(
                x: frame.x,
                y: frame.y,
                width: max(frame.width, 1),
                height: max(frame.height, 1)
            )
        }

        let visibleFrames = visibleFrames.map(validVisibleFrame)
        let bestMatch = visibleFrames
            .map { ($0, $0.intersectionArea(with: frame)) }
            .max { $0.1 < $1.1 }

        if let bestMatch, bestMatch.1 > 0 {
            return fit(
                frame: frame,
                inside: bestMatch.0,
                minimumWidth: minimumWidth,
                minimumHeight: minimumHeight
            )
        }

        let safeFallbackIndex = min(max(fallbackIndex, 0), visibleFrames.count - 1)
        return center(
            frame: frame,
            in: visibleFrames[safeFallbackIndex],
            minimumWidth: minimumWidth,
            minimumHeight: minimumHeight
        )
    }

    public static func nextDisplayIndex(currentIndex: Int, displayCount: Int) -> Int? {
        guard displayCount > 1 else { return nil }
        let normalizedIndex = ((currentIndex % displayCount) + displayCount) % displayCount
        return (normalizedIndex + 1) % displayCount
    }

    private static func fit(
        frame: TaskBoardWindowFrame,
        inside visibleFrame: TaskBoardWindowFrame,
        minimumWidth: Double,
        minimumHeight: Double
    ) -> TaskBoardWindowFrame {
        let width = min(max(frame.width, minimumWidth, 1), visibleFrame.width)
        let height = min(max(frame.height, minimumHeight, 1), visibleFrame.height)
        return TaskBoardWindowFrame(
            x: clamp(
                frame.midX - width / 2,
                lower: visibleFrame.x,
                upper: visibleFrame.x + visibleFrame.width - width
            ),
            y: clamp(
                frame.midY - height / 2,
                lower: visibleFrame.y,
                upper: visibleFrame.y + visibleFrame.height - height
            ),
            width: width,
            height: height
        )
    }

    private static func validVisibleFrame(_ frame: TaskBoardWindowFrame) -> TaskBoardWindowFrame {
        TaskBoardWindowFrame(
            x: frame.x,
            y: frame.y,
            width: max(frame.width, 1),
            height: max(frame.height, 1)
        )
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}

public enum TaskBoardWindowNormalization {
    public static func shouldApply(
        current: TaskBoardWindowFrame,
        recovered: TaskBoardWindowFrame,
        isFullScreen: Bool,
        isFullScreenTransitioning: Bool,
        isInteracting: Bool
    ) -> Bool {
        !isFullScreen
            && !isFullScreenTransitioning
            && !isInteracting
            && !approximatelyEqual(current, recovered)
    }

    private static func approximatelyEqual(
        _ lhs: TaskBoardWindowFrame,
        _ rhs: TaskBoardWindowFrame,
        tolerance: Double = 0.5
    ) -> Bool {
        abs(lhs.x - rhs.x) <= tolerance
            && abs(lhs.y - rhs.y) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}
