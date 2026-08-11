import Foundation

/// What a subscription window is worth, and what expires unused.
///
/// The measurement this exists for: a Max plan's weekly window refills on a
/// schedule and does not roll over, so every percent left untouched at the reset
/// is money that bought nothing. Nobody reports that figure -- Claude Code shows
/// what you have spent, never what you failed to.
///
/// Denominated in dollars of subscription rather than tokens on purpose. Turning
/// an unused percentage into a token count needs a tokens-per-percent anchor, and
/// that anchor moves with model mix and cache ratio -- on this machine cache reads
/// were 96% of volume, which shifts it by an order of magnitude. A token figure
/// would be an estimate wearing a measurement's clothes. The subscription price is
/// exact, and a percentage of an exact number is still exact.
enum PlanValue {
    /// List price per month, keyed by the `rate_limit_tier` the profile endpoint
    /// returns. Deliberately a closed table: an unrecognised tier prices as nil
    /// rather than defaulting, because a plausible-looking wrong number in the
    /// fleet total is worse than a visible gap.
    static let monthlyPrices: [String: Double] = [
        "default_claude_max_20x": 200,
        "default_claude_max_5x":  100,
        "default_claude_pro":      20,
    ]

    static func monthlyPrice(forTier tier: String?) -> Double? {
        guard let tier else { return nil }
        return monthlyPrices[tier]
    }

    /// What one weekly window costs.
    ///
    /// Twelve monthly payments buy 52 weekly windows, not 48. Dividing the month
    /// by four overstates every weekly figure by about 8%, which compounds into
    /// the headline once it is summed across a fleet.
    static func weeklyPrice(forTier tier: String?) -> Double? {
        monthlyPrice(forTier: tier).map { $0 * 12 / 52 }
    }

    /// Dollars of this week's subscription that will expire unused.
    ///
    /// The percentage is clamped rather than trusted: a rolled-over window has
    /// been observed reporting above 100, and unclamped that produces negative
    /// waste which silently subtracts from a fleet total.
    static func expired(weeklyPercent: Int, tier: String?) -> Double? {
        guard let weekly = weeklyPrice(forTier: tier) else { return nil }
        let used = Double(min(100, max(0, weeklyPercent))) / 100
        return weekly * (1 - used)
    }

    /// Below this fraction of the window, a projection is noise.
    ///
    /// `Forecaster` guards the same edge at 1% for its ratio. This is deliberately
    /// stricter: a pace ratio is a live reading the user can watch move, whereas a
    /// dollar figure reads as a finding and will be quoted. Ten percent of a
    /// weekly window is about seventeen hours, which is enough to mean something.
    static let minimumElapsedToProject = 0.10

    /// Dollars this window will lose *at the current burn rate*.
    ///
    /// `expired` answers "what if nothing more is used", which is only honest at
    /// the very end of a window -- run mid-week it reports a freshly-reset account
    /// as wasting its entire price. This projects instead: spend so far divided by
    /// time so far, extended to the reset.
    ///
    /// Returns nil when the window is too young to say anything, rather than
    /// defaulting to a scary number. Declining to answer is a real answer here.
    static func projected(
        weeklyPercent: Int, resetsAt: Date, tier: String?, now: Date = Date()
    ) -> Double? {
        guard let weekly = weeklyPrice(forTier: tier) else { return nil }

        let pace = Forecaster.pace(weeklyPercent: weeklyPercent, resetsAt: resetsAt, now: now)
        guard pace.elapsed >= minimumElapsedToProject else { return nil }

        // pace.ratio is spend-per-unit-time against a flat burn, so it doubles as
        // the fraction of the window this account is on course to consume.
        let projectedUse = min(1, max(0, pace.ratio))
        return weekly * (1 - projectedUse)
    }
}
