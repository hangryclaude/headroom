import Foundation

/// How the week is going, relative to how it *should* be going.
struct Pace: Equatable {
    /// Fraction of the weekly window elapsed, 0...1.
    let elapsed: Double
    /// Fraction of the weekly budget spent, 0...1.
    let spent: Double
    /// spent / elapsed. 1.0 is exactly on pace.
    let ratio: Double
    /// When the weekly budget runs out at the current rate, if it does.
    let exhaustsAt: Date?
    /// When the window refills.
    let resetsAt: Date

    var isOverPace: Bool { ratio > 1.08 }
    var isUnderPace: Bool { ratio < 0.92 }

    /// Runs dry before the window refills.
    var willExhaust: Bool {
        guard let exhaustsAt else { return false }
        return exhaustsAt < resetsAt
    }

    /// How much of the window must elapse before a straight-line projection is
    /// worth anything.
    ///
    /// A linear extrapolation from the first day of a seven-day window is a
    /// rounding error with a weekday attached: one long session on a Monday
    /// reads as "runs out Wednesday". Below this, the app says what it has
    /// measured and declines to forecast.
    static let projectionThreshold = 0.25

    var canProject: Bool { elapsed >= Self.projectionThreshold }

    /// Colour intensity, scaled by how badly the pace overshoots rather than
    /// switched on by a boolean.
    ///
    /// Nil before the window is far enough along to justify a projection. This
    /// is the only coloured element on the glance surface, and it should not be
    /// fired by evidence this thin.
    var severityPercent: Int? {
        guard canProject, willExhaust else { return nil }
        return min(95, 70 + Int((ratio - 1) * 30))
    }
}

/// Weekly pacing, burn rate, and time-to-wall.
///
/// The premise: the 7-day window is the real budget and unused
/// capacity expires, so both directions matter. Burning too fast means a lockout
/// on Thursday; burning too slow means paying for capacity that evaporates on
/// Sunday. A gauge that only warns about the first is half a tool.
///
/// Everything here is a pure function of its inputs so it can be tested against
/// fixtures rather than against whatever this week happens to look like.
enum Forecaster {
    /// The weekly window is seven days; `resets_at` gives the far end, so the
    /// near end is simply seven days earlier.
    static let weekLength: TimeInterval = 7 * 24 * 3600

    static func pace(weeklyPercent: Int, resetsAt: Date, now: Date = Date()) -> Pace {
        let windowStart = resetsAt.addingTimeInterval(-weekLength)
        let elapsed = min(max(now.timeIntervalSince(windowStart) / weekLength, 0), 1)
        let spent = min(max(Double(weeklyPercent) / 100, 0), 1)

        // Guard the first minutes of a window, where dividing by a near-zero
        // elapsed fraction produces a meaningless ratio in the thousands.
        let ratio = elapsed > 0.01 ? spent / elapsed : 1

        var exhaustsAt: Date?
        if spent > 0.001, elapsed > 0.01, ratio > 0 {
            let secondsPerFraction = now.timeIntervalSince(windowStart) / spent
            let remaining = (1 - spent) * secondsPerFraction
            if remaining.isFinite, remaining > 0 {
                exhaustsAt = now.addingTimeInterval(remaining)
            }
        }

        return Pace(
            elapsed: elapsed, spent: spent, ratio: ratio,
            exhaustsAt: exhaustsAt, resetsAt: resetsAt
        )
    }

    /// One sentence a human can act on.
    static func verdict(_ pace: Pace, now: Date = Date()) -> String {
        if pace.spent < 0.005 {
            return "nothing spent this week yet"
        }

        // Early in the window, report the measurement and say plainly that it is
        // too soon to extrapolate — rather than dressing a straight line through
        // two points as a weekday.
        guard pace.canProject else {
            return "\(Int(pace.spent * 100))% spent, \(Int(pace.elapsed * 100))% into the week"
                 + " — too early to project"
        }

        if pace.willExhaust, let exhaustsAt = pace.exhaustsAt {
            return "\(rate(pace)) over pace — weekly runs out \(Self.when(exhaustsAt, now: now))"
        }
        if pace.isOverPace {
            return "\(rate(pace)) over pace, but still lands inside the week"
        }
        if pace.isUnderPace {
            // Unused weekly capacity expires, so this is information, not praise.
            let spare = Int((1 - pace.ratio) * 100)
            return "\(spare)% under pace — unused weekly capacity expires"
        }
        return "on pace"
    }

    private static func rate(_ pace: Pace) -> String {
        String(format: "%.1f×", pace.ratio)
    }

    /// "Tuesday afternoon" rather than a timestamp: for something days away, the
    /// useful precision is which day and roughly when, and a false "~3:47 pm"
    /// implies confidence a linear extrapolation has not earned.
    static func when(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(date) {
            day = "today"
        } else if calendar.isDateInTomorrow(date) {
            day = "tomorrow"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            day = formatter.string(from: date)
        }
        return "\(day) \(partOfDay(date, calendar: calendar))"
    }

    private static func partOfDay(_ date: Date, calendar: Calendar) -> String {
        switch calendar.component(.hour, from: date) {
        case 0..<5:   return "overnight"
        case 5..<12:  return "morning"
        case 12..<17: return "afternoon"
        case 17..<21: return "evening"
        default:      return "night"
        }
    }

    // MARK: The 5-hour throttle

    /// Whether the session window will run out before it resets.
    ///
    /// Unlike the weekly figure this one is measured, not inferred: tokens per
    /// minute come from the transcripts, and the session percentage comes from
    /// the server. They are different units, so the projection scales the
    /// observed percentage by the observed rate rather than pretending to know
    /// how many tokens a percent is worth.
    static func sessionWall(
        percent: Int,
        resetsAt: Date,
        windowLength: TimeInterval = 5 * 3600,
        now: Date = Date()
    ) -> Date? {
        let windowStart = resetsAt.addingTimeInterval(-windowLength)
        let elapsed = now.timeIntervalSince(windowStart)
        let spent = Double(percent) / 100
        guard elapsed > 60, spent > 0.01 else { return nil }

        let remaining = (1 - spent) * (elapsed / spent)
        guard remaining.isFinite, remaining > 0 else { return nil }
        let wall = now.addingTimeInterval(remaining)
        return wall < resetsAt ? wall : nil
    }
}
