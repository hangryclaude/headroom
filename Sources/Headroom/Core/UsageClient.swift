import Foundation

/// Fetches quota for *any* account, not just the signed-in one.
///
/// This is the capability that neither reference product has. SessionWatcher
/// reads local files, so it can only ever describe the active account and cannot
/// switch. caam can switch but explicitly defers per-account usage (its issue
/// #16) and ships `ClaudeRefreshDisabled = true`. Reading `~/.claude.json` gets
/// you the active account for free; asking the server with a stored token is the
/// only way to answer "which of my accounts actually has room right now".
///
/// The endpoint contract is the one Claude Code itself uses.
struct UsageClient {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"

    enum Failure: Error, CustomStringConvertible {
        case tokenExpired
        case http(Int)
        case noToken
        case transport(String)

        var description: String {
            switch self {
            case .tokenExpired:      return "token expired"
            case .http(let code):    return "http \(code)"
            case .noToken:           return "no token"
            case .transport(let m):  return m
            }
        }

        /// Short enough for a menu row. Borrowed from caam's rule that a failed
        /// fetch must render as "no usage: <reason>" and never as an empty 0%
        /// bar, because an empty gauge reads as "plenty left" (their issue #37).
        var short: String { description }
    }

    var session: URLSession = .shared

    func fetch(accessToken: String) async throws -> QuotaSnapshot {
        guard !accessToken.isEmpty else { throw Failure.noToken }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Headroom/0.1 (macOS)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 401/403 mean this account's token needs refreshing, which is a
        // different problem from the endpoint being down. Store forces one
        // refresh and retries before it considers the account unavailable.
        if status == 401 || status == 403 { throw Failure.tokenExpired }
        guard (200..<300).contains(status) else { throw Failure.http(status) }

        return try Self.parse(data)
    }

    /// The response is the same object Claude Code caches into `~/.claude.json`
    /// under `cachedUsageUtilization.utilization`, so it reuses the same parser.
    ///
    /// One landmine, learned from caam's issue #52: `utilization` is a percent on
    /// a 0-100 scale, not a 0-1 fraction. Reading 1.0 as "100%" renders a barely
    /// touched subscription as exhausted.
    static func parse(_ data: Data) throws -> QuotaSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.transport("unreadable response") }

        // The endpoint returns the utilization object directly; the on-disk cache
        // nests it one level down. Accept both so the two paths share a parser.
        let utilization = (root["utilization"] as? [String: Any]) ?? root
        let limits = (utilization["limits"] as? [[String: Any]]) ?? []

        return QuotaSnapshot(
            fetchedAt: Date(),
            accountUUID: root["accountUuid"] as? String,
            limits: limits.compactMap { QuotaReader.parseLimit($0, now: Date()) }
        )
    }
}
