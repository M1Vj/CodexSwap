import Foundation

/// Localized human-readable captions for quota-window reset timestamps.
///
/// The underlying `UsageWindow.resetAt` value remains an exact `Date`; this
/// type only controls how that value is presented to a person.  Keeping the
/// clock and formatting context injectable makes boundary and locale behavior
/// deterministic in tests and keeps each UI surface consistent.
public struct UsageResetPresentation: Sendable {
    public static let fiveHourWindowSeconds = 18_000
    public static let weeklyWindowSeconds = 604_800

    public let now: Date
    public let locale: Locale
    public let calendar: Calendar
    public let timeZone: TimeZone

    public init(
        now: Date = Date(),
        locale: Locale = .current,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) {
        self.now = now
        self.locale = locale
        self.timeZone = timeZone

        var configuredCalendar = calendar
        configuredCalendar.locale = locale
        configuredCalendar.timeZone = timeZone
        self.calendar = configuredCalendar
    }

    /// Returns an app caption, or `nil` when no reset timestamp is available.
    public func appCaption(for window: UsageWindow) -> String? {
        appCaption(windowSeconds: window.windowSeconds, resetAt: window.resetAt)
    }

    /// Returns a human-readable CLI caption.  Unlike the app variant, a
    /// missing timestamp is represented by `-` and an elapsed reset by the
    /// ASCII-friendly `resetting` label.
    public func cliCaption(for window: UsageWindow) -> String {
        cliCaption(windowSeconds: window.windowSeconds, resetAt: window.resetAt)
    }

    /// Returns an app caption for a quota window with an optional duration.
    /// Unknown durations still receive the full localized date and time.
    public func appCaption(windowSeconds: Int?, resetAt: Date?) -> String? {
        guard let resetAt else { return nil }
        guard resetAt > now else { return "resetting…" }
        return "Resets \(formatted(resetAt, windowSeconds: windowSeconds))"
    }

    /// Returns a human-readable CLI caption for a quota window with an
    /// optional duration.
    public func cliCaption(windowSeconds: Int?, resetAt: Date?) -> String {
        guard let resetAt else { return "-" }
        guard resetAt > now else { return "resetting" }
        return "Resets \(formatted(resetAt, windowSeconds: windowSeconds))"
    }

    private func formatted(_ date: Date, windowSeconds: Int?) -> String {
        let dateStyle: Date.FormatStyle.DateStyle =
            windowSeconds == Self.fiveHourWindowSeconds ? .omitted : .abbreviated
        var style = Date.FormatStyle(date: dateStyle, time: .shortened)
        style.locale = locale
        style.calendar = calendar
        style.timeZone = timeZone
        return date.formatted(style)
    }
}
