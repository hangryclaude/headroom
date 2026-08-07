import Foundation

/// Which limit window a reading describes.
enum LimitKind: Equatable {
    case session              // the 5-hour rolling window
    case weeklyAll            // the 7-day cap across all models
    case weeklyScoped(String) // 7-day cap for one model, e.g. "Fable"

    var label: String {
        switch self {
        case .session:            return "SESSION"
        case .weeklyAll:          return "WEEKLY"
        case .weeklyScoped(let m): return m.uppercased()
        }
    }
}

/// What we actually know about a window right now.
///
/// The distinction that matters: Claude Code only refreshes the quota cache when
/// it talks to the server, so a percentage on disk can outlive the window it
/// describes. Observed on this machine: the cache read 79% for a session window
/// whose `resets_at` had already passed. Rendering that 79% would be a lie -- the
/// window had rolled over and the true figure was near zero. `.rolledOver` exists
/// so the UI can say "reset" instead of inventing either number.
enum Reading: Equatable {
    case live(Int)
    case rolledOver
    case unknown

    var percent: Int? {
        if case .live(let p) = self { return p }
        return nil
    }
}

enum Severity: String, Codable, Equatable {
    case normal, warning, critical

    /// Derived rather than trusted: the server sends `normal`/`warning`, but the
    /// threshold for "you are about to lose your session" is the user's to set, not
    /// Anthropic's. Kept as a separate step so the user's threshold wins.
    static func forPercent(_ p: Int, warnAt: Int, criticalAt: Int) -> Severity {
        if p >= criticalAt { return .critical }
        if p >= warnAt { return .warning }
        return .normal
    }
}

struct Limit: Equatable {
    let kind: LimitKind
    let reading: Reading
    let resetsAt: Date?
    let isActive: Bool

    /// Time until this window rolls over. Nil when unknown or already elapsed.
    func timeRemaining(now: Date = Date()) -> TimeInterval? {
        guard let resetsAt, resetsAt > now else { return nil }
        return resetsAt.timeIntervalSince(now)
    }
}

struct QuotaSnapshot: Equatable {
    let fetchedAt: Date
    let accountUUID: String?
    let limits: [Limit]

    /// How long ago Claude Code last refreshed this from the server.
    func age(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(fetchedAt) }

    /// Past this, the numbers are old enough that the UI should visibly dim them
    /// and show the age. Chosen to sit just above Claude Code's own refresh
    /// cadence so an actively-used session never looks stale.
    static let staleAfter: TimeInterval = 15 * 60

    func isStale(now: Date = Date()) -> Bool { age(now: now) > Self.staleAfter }

    func limit(_ kind: LimitKind) -> Limit? { limits.first { $0.kind == kind } }

    var session: Limit? { limit(.session) }
    var weekly: Limit? { limit(.weeklyAll) }
}

// MARK: - Reading it off disk

enum QuotaError: Error, CustomStringConvertible {
    case noConfig(URL)
    case noUsageCache

    var description: String {
        switch self {
        case .noConfig(let url): return "no Claude config at \(url.path)"
        case .noUsageCache:      return "config has no cachedUsageUtilization -- run Claude Code once"
        }
    }
}

/// Parses `~/.claude.json` -> `cachedUsageUtilization`.
///
/// Hand-rolled `JSONSerialization` rather than `Codable` on purpose. This is a
/// large file owned by another program, full of keys we neither know nor care
/// about, and the server keeps adding codenamed limit buckets (`tangelo`,
/// `iguana_necktie`, `nimbus_quill`). A strict decoder would break on a key we
/// have never seen; picking out the three fields we need cannot.
struct QuotaReader {
    let configURL: URL

    init(configURL: URL = ClaudePaths.configJSON) {
        self.configURL = configURL
    }

    func read(now: Date = Date()) throws -> QuotaSnapshot {
        guard let data = FileManager.default.contents(atPath: configURL.path) else {
            throw QuotaError.noConfig(configURL)
        }
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let cache = root["cachedUsageUtilization"] as? [String: Any] else {
            throw QuotaError.noUsageCache
        }

        let fetchedAt = (cache["fetchedAtMs"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1000)
        } ?? .distantPast
        let account = cache["accountUuid"] as? String

        let raw = (cache["utilization"] as? [String: Any])?["limits"] as? [[String: Any]] ?? []
        let limits = raw.compactMap { Self.parseLimit($0, now: now) }

        return QuotaSnapshot(fetchedAt: fetchedAt, accountUUID: account, limits: limits)
    }

    /// Shared with `UsageClient`: the live endpoint returns the same `limits[]`
    /// objects that Claude Code caches to disk, so both paths parse identically.
    static func parseLimit(_ entry: [String: Any], now: Date) -> Limit? {
        guard let kindString = entry["kind"] as? String else { return nil }

        let kind: LimitKind
        switch kindString {
        case "session":
            kind = .session
        case "weekly_all":
            kind = .weeklyAll
        case "weekly_scoped":
            // The model name lives two levels down and `id` is routinely null
            // while `display_name` is populated, so display_name is the only
            // usable handle on which model a scoped cap belongs to.
            let scope = entry["scope"] as? [String: Any]
            let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
            kind = .weeklyScoped(model ?? "Scoped")
        default:
            // A bucket we do not recognise yet. Dropping it is right: the server
            // ships placeholder limits (all-null) long before they mean anything.
            return nil
        }

        let resetsAt = (entry["resets_at"] as? String).flatMap(parseTimestamp)

        let reading: Reading
        if let resetsAt, resetsAt <= now {
            reading = .rolledOver
        } else if let percent = entry["percent"] as? Int {
            reading = .live(percent)
        } else {
            reading = .unknown
        }

        return Limit(
            kind: kind,
            reading: reading,
            resetsAt: resetsAt,
            isActive: entry["is_active"] as? Bool ?? false
        )
    }

    /// `2026-08-06T22:40:00.473963+00:00` -- six fractional digits and an offset.
    /// Scoped caps often carry no reset at all, and nothing guarantees the
    /// fractional part, so both shapes are tried.
    ///
    /// Built per call rather than cached in a static: `ISO8601DateFormatter` is
    /// not `Sendable`, and there are three timestamps per poll, so a shared
    /// instance would buy nothing and cost a concurrency escape hatch.
    static func parseTimestamp(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
