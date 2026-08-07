import Foundation

enum RefreshOutcome: Equatable {
    case stillValid
    case refreshed(Credentials)
    /// Transient. Emphatically *not* a dead account.
    case rateLimited(String)
    /// The refresh token is genuinely dead; only a re-login fixes it.
    case needsLogin(String)
    case failed(String)
    case busy

    var isTerminal: Bool { if case .needsLogin = self { return true }; return false }
}

/// Keeps a stored account's access token alive so its usage can be polled.
///
/// An account sitting in the vault goes dark on its own: the access token
/// expires, `UsageClient` starts returning 401, and the row that is supposed to
/// tell you where to switch says "token expired" instead. caam does not solve
/// this -- it ships `ClaudeRefreshDisabled = true` with the endpoint marked
/// speculative. The working contract here comes from an earlier tool that
/// solved this exact problem.
///
/// **This is the most dangerous code in the app.** Anthropic rotates the refresh
/// token on every redemption, so a crash between the server rotating and us
/// persisting burns the account permanently, and two processes redeeming the
/// same token concurrently does the same thing (that is what killed an
/// account on 2026-07-08). The mitigations below are ordered so that
/// the worst case is always recoverable by hand:
///
///   1. a cross-process mutex, so only one redemption is ever in flight;
///   2. the whole credential blob is backed up before the call;
///   3. the RAW server response is written to disk *before* it is parsed, so a
///      crash during parsing still leaves the rotated pair on disk;
///   4. only then is the blob merged and written back.
struct TokenRefresher {
    /// Claude Code's own OAuth application.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    /// Refresh once there is less than this much life left.
    static let skew: TimeInterval = 10 * 60

    /// A lock older than this is assumed to belong to a dead process.
    static let lockTimeout: TimeInterval = 2 * 60

    var session: URLSession = .shared

    /// - Parameter persist: called with the rotated credentials **while the mutex
    ///   is still held**. Persisting after this function returned left the one
    ///   window that actually matters unprotected: the server had rotated, and a
    ///   second process could redeem the same token before the first had written
    ///   it anywhere.
    func refreshIfNeeded(
        _ credentials: Credentials,
        directory: URL,
        force: Bool = false,
        persist: (@Sendable (Credentials) throws -> Void)? = nil
    ) async -> RefreshOutcome {
        if !force, let expiresAt = credentials.expiresAt,
           expiresAt.timeIntervalSinceNow > Self.skew {
            return .stillValid
        }
        guard let refreshToken = credentials.refreshToken else {
            return .needsLogin("no refresh token stored")
        }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let lock = directory.appending(path: ".refresh.lock")
        guard let ownership = Self.acquireLock(lock) else { return .busy }
        defer { Self.releaseLock(lock, ownership: ownership) }

        // (2) Backup before anything can go wrong.
        try? credentials.raw.write(
            to: directory.appending(path: ".credentials.backup.json"), options: .atomic)

        let raw: Data
        do {
            raw = try await post(refreshToken: refreshToken)
        } catch {
            return .failed(error.localizedDescription)
        }

        // (3) A rotated pair goes to disk before a single byte is parsed, so a
        // crash on the next line still leaves it recoverable by hand.
        //
        // Only responses that actually carry a token are written here. Writing
        // unconditionally meant the next attempt's error response -- a 429, say
        // -- overwrote the one copy of a token that had already been consumed
        // server-side, destroying the only means of recovery.
        if Self.containsToken(raw) {
            Self.writeDurably(raw, to: directory.appending(path: ".refresh-raw.json"))
        } else {
            Self.writeDurably(raw, to: directory.appending(path: ".refresh-last-error.json"))
        }

        guard let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return .failed("unparseable token response")
        }

        guard let accessToken = object["access_token"] as? String, !accessToken.isEmpty else {
            return Self.classify(object)
        }

        // (4) Merge, preserving every field we did not come here to change.
        guard let merged = Self.merge(object, into: credentials) else {
            return .failed("could not merge rotated token")
        }

        // (5) Persist inside the lock. A throw here is reported rather than
        // swallowed: the caller must know the vault copy is behind the server.
        if let persist {
            do { try persist(merged) }
            catch { return .failed("rotated but could not save: \(error)") }
        }
        return .refreshed(merged)
    }

    /// Cheap byte scan, deliberately not a parse -- the whole point of writing
    /// the raw bytes first is that nothing has been parsed yet.
    static func containsToken(_ data: Data) -> Bool {
        data.range(of: Data("\"access_token\"".utf8)) != nil
    }

    private func post(refreshToken: String) async throws -> Data {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Blank, deliberately. This endpoint 429s on common default User-Agents
        // -- an earlier tool spent three days reading false "rate limited" before
        // discovering that the identical request with the UA suppressed goes
        // straight through. Verified that URLSession does send an empty header
        // rather than substituting its own.
        request.setValue("", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ])

        let (data, _) = try await session.data(for: request)
        return data
    }

    /// The endpoint answers errors in two different shapes:
    ///   OAuth:     {"error":"invalid_grant","error_description":"..."}
    ///   Anthropic: {"error":{"type":"rate_limit_error","message":"..."}}
    ///
    /// Only `invalid_grant` means the token is actually dead. Reporting a rate
    /// limit as "needs login" would send you to burn a perfectly good account.
    static func classify(_ object: [String: Any]) -> RefreshOutcome {
        let error = object["error"]
        let type: String
        var message: String

        if let string = error as? String {
            type = string
            message = object["error_description"] as? String ?? string
        } else if let nested = error as? [String: Any] {
            type = nested["type"] as? String ?? ""
            message = nested["message"] as? String ?? type
        } else {
            return .failed("no access_token in response")
        }
        if message.isEmpty { message = type }

        if type.range(of: "rate_limit|overloaded|api_error|5\\d\\d", options: .regularExpression) != nil {
            return .rateLimited(message)
        }
        if type.range(of: "invalid_grant|invalid_client|unauthorized", options: .regularExpression) != nil {
            return .needsLogin(message)
        }
        return .failed(message)
    }

    /// Replaces the rotated fields, in whichever shape the blob uses.
    ///
    /// Writes into the *one* container that actually holds the tokens, and adds a
    /// key that is not already there. An earlier version only ever overwrote keys
    /// that already existed, which silently dropped the rotated refresh token
    /// whenever the stored blob had no `refreshToken` key of its own -- the
    /// server had consumed the old one, we kept the old one, and the account was
    /// dead the next time it was used. Returns nil rather than persisting a blob
    /// it could not actually update.
    static func merge(_ response: [String: Any], into credentials: Credentials) -> Credentials? {
        guard var root = try? JSONSerialization.jsonObject(with: credentials.raw) as? [String: Any]
        else { return nil }

        let accessToken = response["access_token"] as? String
        let refreshToken = response["refresh_token"] as? String
        let expiresIn = (response["expires_in"] as? Double)
            ?? (response["expires_in"] as? Int).map(Double.init)
        guard accessToken != nil else { return nil }

        /// Which nested object holds the credential, and which naming style it
        /// uses. Both are properties of the blob we were given, not assumptions.
        func locate(_ container: [String: Any]) -> Bool {
            container["accessToken"] != nil || container["access_token"] != nil
        }

        func apply(to container: inout [String: Any]) {
            let snake = container["access_token"] != nil
            let accessKey = snake ? "access_token" : "accessToken"
            let refreshKey = snake ? "refresh_token" : "refreshToken"
            let expiryKey = snake ? "expires_at" : "expiresAt"

            if let accessToken { container[accessKey] = accessToken }
            // Absent from the response means "keep the current one". Only an
            // explicitly returned token replaces what is stored.
            if let refreshToken { container[refreshKey] = refreshToken }
            if let expiresIn {
                container[expiryKey] = Date().addingTimeInterval(expiresIn)
                    .timeIntervalSince1970 * 1000
            }
        }

        var updated = false
        for wrapper in ["claudeAiOauth", "oauthToken", "claude_ai_oauth"] {
            if var nested = root[wrapper] as? [String: Any], locate(nested) {
                apply(to: &nested)
                root[wrapper] = nested
                updated = true
                break
            }
        }
        if !updated, locate(root) {
            apply(to: &root)
            updated = true
        }

        // Nothing recognisable to update. Persisting here would write a blob that
        // still carries the consumed token while the server has moved on.
        guard updated, let data = try? JSONSerialization.data(withJSONObject: root)
        else { return nil }
        return Credentials(raw: data)
    }

    // MARK: Mutex

    /// Takes the lock, returning an ownership token, or nil if it is held.
    ///
    /// `open(O_CREAT | O_EXCL)` is the primitive: the kernel creates the file and
    /// fails if it already exists, in one uninterruptible step, and the owner
    /// token goes into that same exclusively-held descriptor.
    ///
    /// An earlier version used `mkdir` and wrote the owner as a second step. That
    /// left a real gap -- two processes could both judge a stale lock dead, and
    /// the loser's remove could delete the directory the winner had just created,
    /// putting two token redemptions in flight at once. Since concurrent
    /// redemption is precisely what destroys an account, closing that window is
    /// worth the few extra lines.
    ///
    /// (A liveness poll was tried instead in a previous life and abandoned: it
    /// answered "up" essentially always and narrowed nothing.)
    static func acquireLock(_ url: URL) -> String? {
        let token = UUID().uuidString
        if claim(url, token: token) { return token }

        // Held. Break it only if whoever holds it is long dead.
        guard let created = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.creationDate] as? Date,
              Date().timeIntervalSince(created) > lockTimeout
        else { return nil }

        try? FileManager.default.removeItem(at: url)
        // Still exclusive: if a competitor broke it first and won the race, this
        // fails and we back off rather than joining them inside.
        return claim(url, token: token) ? token : nil
    }

    private static func claim(_ url: URL, token: String) -> Bool {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var bytes = Array(token.utf8)
        return write(descriptor, &bytes, bytes.count) == bytes.count
    }

    static func releaseLock(_ url: URL, ownership: String) {
        let current = (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
        // Somebody else's lock now. Leaving it alone is the safe failure.
        guard current == ownership else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes and fsyncs, so the bytes are on the platter before we return. A
    /// normal write can sit in the page cache and vanish in a crash, which for
    /// this particular file is the difference between a recoverable account and
    /// a dead one.
    static func writeDurably(_ data: Data, to url: URL) {
        guard let handle = FileHandle(forWritingAtPath: url.path) ?? {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            return FileHandle(forWritingAtPath: url.path)
        }() else { return }

        try? handle.truncate(atOffset: 0)
        try? handle.write(contentsOf: data)
        try? handle.synchronize()
        try? handle.close()
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
