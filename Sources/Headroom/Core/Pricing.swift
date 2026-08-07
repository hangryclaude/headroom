import Foundation

/// Dollars per million tokens for one model.
struct Rate: Equatable {
    let input: Double
    let output: Double

    /// Cache reads bill at ~0.1x base input.
    var cacheRead: Double { input * 0.1 }

    /// Cache writes bill at 1.25x for the 5-minute TTL and 2x for the 1-hour.
    /// Keeping them separate is why `TranscriptIndexer` bothers to split
    /// `ephemeral_5m` from `ephemeral_1h` -- collapsing them would misprice the
    /// dominant line item on a cache-heavy workload by up to 60%.
    var cacheWrite5m: Double { input * 1.25 }
    var cacheWrite1h: Double { input * 2.0 }
}

/// Model pricing, current as of 2026-08.
///
/// Deliberately a static table rather than a live lookup: it changes rarely, a
/// menu bar app should not need the network to render a number, and a wrong
/// guess here is worse than a stale one. Verified against Anthropic's published
/// per-million-token rates rather than recalled.
enum Pricing {
    static let rates: [String: Rate] = [
        "claude-opus-5":   Rate(input: 5, output: 25),
        "claude-fable-5":  Rate(input: 10, output: 50),
        "claude-sonnet-5": Rate(input: 3, output: 15),
        "claude-haiku-4-5": Rate(input: 1, output: 5),
        "claude-opus-4-8": Rate(input: 5, output: 25),
        "claude-opus-4-7": Rate(input: 5, output: 25),
        "claude-sonnet-4-6": Rate(input: 3, output: 15),
    ]

    /// Resolves a transcript's model string to a rate.
    ///
    /// Transcripts carry both bare ids (`claude-opus-5`) and date-suffixed ones
    /// (`claude-haiku-4-5-20251001`), so an exact-match lookup silently drops
    /// whole models from the total. Longest-prefix wins, so `claude-opus-4-8`
    /// cannot be swallowed by a shorter key.
    static func rate(for model: String) -> Rate? {
        if let exact = rates[model] { return exact }
        return rates
            .filter { model.hasPrefix($0.key) }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    static func cost(_ usage: TokenUsage, model: String) -> Double? {
        guard let rate = rate(for: model) else { return nil }
        let million = 1_000_000.0
        return Double(usage.input) / million * rate.input
            + Double(usage.output) / million * rate.output
            + Double(usage.cacheRead) / million * rate.cacheRead
            + Double(usage.cacheWrite5m) / million * rate.cacheWrite5m
            + Double(usage.cacheWrite1h) / million * rate.cacheWrite1h
    }

    /// Total across a per-model breakdown, plus whichever models had no rate so
    /// the UI can say the figure is partial instead of quietly under-reporting.
    static func cost(_ byModel: [String: TokenUsage]) -> (total: Double, unpriced: [String]) {
        var total = 0.0
        var unpriced: [String] = []
        for (model, usage) in byModel {
            if let dollars = cost(usage, model: model) {
                total += dollars
            } else if usage.total > 0 {
                unpriced.append(model)
            }
        }
        return (total, unpriced.sorted())
    }

    static func format(_ dollars: Double) -> String {
        if dollars >= 100 { return String(format: "$%.0f", dollars) }
        if dollars >= 10 { return String(format: "$%.1f", dollars) }
        return String(format: "$%.2f", dollars)
    }
}
