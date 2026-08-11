import Foundation

/// One Devin session, reduced to the fields a menu bar row can actually show.
///
/// The v3 session object carries about twenty fields; all but a handful describe
/// relations (parent/child sessions, playbooks, PRs) that a four-line summary has
/// no room for. Decoding only what is displayed keeps the parser tolerant of
/// upstream additions, which matters more here than on the Anthropic endpoint —
/// Devin's API is versioned and still moving.
struct DevinSession: Equatable {

    /// The seven values the list endpoint documents, plus a degradation case.
    ///
    /// `unknown` exists so that one new status upstream cannot blank the whole
    /// section. A session with a status Headroom does not recognise is still a
    /// session, and saying so is better than silently dropping it from the count.
    enum Status: String, Equatable {
        case new, claimed, running, exit, error, suspended, resuming, unknown

        init(api raw: String) {
            self = Status(rawValue: raw.lowercased()) ?? .unknown
            // `unknown` is a real rawValue, so a literal "unknown" from the server
            // would round-trip into the degradation case. That is the right answer.
        }

        /// Whether Devin is doing work right now, as opposed to parked or done.
        ///
        /// `claimed` and `resuming` are both transient states on the way into
        /// `running`; counting them as idle makes the tally flicker to zero
        /// during the seconds a session is starting up.
        var isActive: Bool {
            switch self {
            case .new, .claimed, .running, .resuming: return true
            case .exit, .error, .suspended, .unknown:  return false
            }
        }

        /// Parked, waiting on a human. Distinct from finished.
        var isAsleep: Bool { self == .suspended }

        var isFailed: Bool { self == .error }

        /// What the row prints. `status_detail` is preferred when present because
        /// "waiting_for_user" tells you more than "suspended".
        var label: String {
            switch self {
            case .new:       return "queued"
            case .claimed:   return "starting"
            case .running:   return "running"
            case .resuming:  return "resuming"
            case .suspended: return "asleep"
            case .exit:      return "finished"
            case .error:     return "failed"
            case .unknown:   return "unknown"
            }
        }
    }

    let id: String
    let url: URL?
    let title: String?
    let status: Status
    let statusDetail: String?
    let acusConsumed: Double
    let createdAt: Date
    let updatedAt: Date
    let isArchived: Bool

    /// `title` is optional in the schema and genuinely absent on API-created
    /// sessions. An empty row reads as a broken fetch, so fall back to the id.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return id
    }
}

/// Rolls a session list into the numbers the popover shows.
///
/// Kept separate from the client so the arithmetic is testable without a network
/// stub, matching how `Forecaster` sits apart from `QuotaReader`.
enum DevinUsage {

    struct Summary: Equatable {
        var active: Int
        var asleep: Int
        var failed: Int
        var acus: Double
        /// nil unless an allowance is configured. There is no endpoint that
        /// reports a self-serve plan's ACU limit, so the denominator can only
        /// ever come from the user. Showing a percentage without one would mean
        /// inventing it.
        var percent: Double?
        /// True when the org returned no sessions at all. The caller needs this
        /// to distinguish "nothing has run" from "not set up", because a zeroed
        /// gauge otherwise reads as plenty of headroom — the same trap the quota
        /// gauge already guards against.
        var isEmpty: Bool
    }

    /// - Parameter since: start of the billing period. nil sums everything, which
    ///   is what a fresh org wants before any period has elapsed.
    static func summarise(
        _ sessions: [DevinSession],
        allowance: Double?,
        now: Date,
        since: Date? = nil
    ) -> Summary {
        let scoped = sessions.filter { session in
            guard let since else { return true }
            return session.createdAt >= since
        }
        let acus = scoped.reduce(0) { $0 + $1.acusConsumed }

        // Counts describe the current moment, so they read the live list rather
        // than the period-scoped one: a session that started last month and is
        // still running is still running.
        return Summary(
            active: sessions.filter { $0.status.isActive }.count,
            asleep: sessions.filter { $0.status.isAsleep }.count,
            failed: sessions.filter { $0.status.isFailed }.count,
            acus: acus,
            percent: allowance.flatMap { $0 > 0 ? acus / $0 * 100 : nil },
            isEmpty: sessions.isEmpty
        )
    }
}
