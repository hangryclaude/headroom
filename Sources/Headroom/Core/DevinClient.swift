import Foundation

/// Reads Devin sessions for one organisation.
///
/// Deliberately narrow: list sessions, nothing else. Headroom is a gauge, and a
/// gauge that can also start and terminate agent sessions is a different, riskier
/// program. Every request this type makes is a GET.
///
/// There is no consumption endpoint on a self-serve plan — `/v3/enterprise/*`
/// returns 403 for a standard org key — so ACUs are summed from the session list
/// instead. `acus_consumed` is a required field on every session, which makes the
/// sum exact rather than an estimate; what cannot be known from the API is the
/// plan's *allowance*, so that stays user-configured.
struct DevinClient {
    static let host = "https://api.devin.ai"

    enum Failure: Error, CustomStringConvertible {
        case noKey
        case noOrg
        case unauthorized
        case orgNotFound
        case http(Int)
        case transport(String)
        case malformed

        var description: String {
            switch self {
            case .noKey:            return "no Devin API key"
            case .noOrg:            return "no Devin org id set"
            case .unauthorized:     return "key rejected"
            case .orgNotFound:      return "org not found"
            case .http(let code):   return "http \(code)"
            case .transport(let m): return m
            case .malformed:        return "unreadable response"
            }
        }

        /// Same contract as `UsageClient.Failure.short`: a failed fetch must
        /// render as a stated reason, never as an empty zero bar.
        var short: String { description }
    }

    var session: URLSession = .shared

    /// - Parameter orgID: the `org-…` identifier from Settings ▸ Service Users.
    ///   The bare UUID does not work; the endpoint answers "Organization not
    ///   found" for it, which is indistinguishable from a wrong org.
    func fetchSessions(orgID: String, apiKey: String, limit: Int = 20) async throws -> [DevinSession] {
        guard !apiKey.isEmpty else { throw Failure.noKey }
        guard !orgID.isEmpty else { throw Failure.noOrg }

        var components = URLComponents(string: "\(Self.host)/v3/organizations/\(orgID)/sessions")!
        // `qs` is documented as a required SessionsQueryParams object but the
        // endpoint answers 200 without it. Sending it as JSON is the documented
        // shape and pins the page size; the bare call was verified to work too,
        // so a rejection here is not fatal to the feature.
        components.queryItems = [URLQueryItem(name: "qs", value: #"{"limit":\#(limit)}"#)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
        switch status {
        case 200..<300:
            return try Self.parse(data)
        case 401, 403:
            throw Failure.unauthorized
        case 404:
            // The API returns 404 with detail "Organization not found" for a bad
            // org id, and a plain 404 for a path that does not exist. Only the
            // first is worth a specific message.
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["detail"] as? String } ?? ""
            throw detail.localizedCaseInsensitiveContains("organization")
                ? Failure.orgNotFound
                : Failure.http(404)
        default:
            throw Failure.http(status)
        }
    }

    /// Parses the paginated envelope. `JSONSerialization` rather than `Codable`
    /// to match `UsageClient` and to keep a single unexpected field from
    /// invalidating the whole response.
    static func parse(_ data: Data) throws -> [DevinSession] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.malformed }

        // Accept a bare array too: the envelope is documented, but an endpoint
        // that once returned a list directly is cheap to keep tolerating.
        let items = (root["items"] as? [[String: Any]]) ?? []

        return items.compactMap { item in
            // session_id is required by the schema; an item without one is not a
            // session we can link to, so drop it rather than invent an id.
            guard let id = item["session_id"] as? String else { return nil }

            return DevinSession(
                id: id,
                url: (item["url"] as? String).flatMap(URL.init(string:)),
                title: item["title"] as? String,
                status: DevinSession.Status(api: item["status"] as? String ?? ""),
                statusDetail: item["status_detail"] as? String,
                acusConsumed: (item["acus_consumed"] as? NSNumber)?.doubleValue ?? 0,
                createdAt: date(from: item["created_at"]),
                updatedAt: date(from: item["updated_at"]),
                isArchived: item["is_archived"] as? Bool ?? false
            )
        }
    }

    /// The schema says the timestamps are integers but not what unit. Claude's
    /// credential blob had the same ambiguity and the same fix: anything large
    /// enough to be a year past ~5138 in seconds is really milliseconds.
    static func date(from value: Any?) -> Date {
        guard let number = (value as? NSNumber)?.doubleValue else { return .distantPast }
        return Date(timeIntervalSince1970: number > 1e11 ? number / 1000 : number)
    }
}
