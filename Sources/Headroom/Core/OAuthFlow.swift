import CryptoKit
import Foundation

/// Signs a new account in without disturbing the one already signed in.
///
/// The alternative -- shelling out to `claude /login` -- authenticates *into the
/// Keychain*, which is a single slot shared by every Claude account on this
/// machine. So adding account two means signing out of account one, and the
/// vault copy of account one had better be current or its token is stranded.
/// That ordering constraint is the whole reason adding accounts felt fragile.
///
/// Running the OAuth exchange here removes it: the tokens come back to us
/// directly and go straight into the vault. The Keychain is never touched, so
/// the live session keeps working while accounts are added around it.
///
/// Every constant below was read out of the Claude Code binary rather than
/// guessed, because a wrong `client_id` or scope set mints a token that looks
/// fine until Claude Code rejects it after a swap.
enum OAuthFlow {
    /// Claude Code's own OAuth application -- shared with `TokenRefresher` so a
    /// token minted here refreshes through exactly the same path later.
    static let clientID = TokenRefresher.clientID

    /// The subscription (claude.ai) authorize page, not the console one. Console
    /// issues API-key credentials billed per token; only this endpoint yields a
    /// credential carrying a Max plan's quota.
    static let authorizeURL = URL(string: "https://claude.com/cai/oauth/authorize")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    /// A hosted page that displays the code rather than a `localhost` listener.
    /// A menu bar app binding a port would need it free, reachable, and torn down
    /// on every failure path; a paste is three seconds and has no failure modes.
    static let redirectURI = "https://platform.claude.com/oauth/code/callback"

    /// Where the plan tier actually lives.
    ///
    /// The token response carries the organization's uuid and name but not its
    /// type or rate limit tier, so a credential minted here has no plan until
    /// something asks for it. Claude Code hits this endpoint during bootstrap and
    /// writes the answer into `~/.claude.json`; doing it at sign-in means an
    /// account shows its real plan straight away instead of after its first swap.
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    /// Exactly the set the live credential carries. Requesting fewer would mint a
    /// token that works for reading usage but quietly lacks the permissions
    /// Claude Code needs once the account is swapped in.
    static let scopes = [
        "user:file_upload",
        "user:inference",
        "user:mcp_servers",
        "user:profile",
        "user:sessions:claude_code",
    ]

    /// A flow in progress. The verifier must survive until the code comes back,
    /// which is the entire point of PKCE: the authorization code alone is useless
    /// to anyone who intercepts it.
    struct Pending {
        let verifier: String
        let state: String
        let url: URL
    }

    enum FlowError: LocalizedError {
        case noCode
        case rejected(String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .noCode:
                return "no code pasted"
            case .rejected(let why):
                return why
            case .malformed(let what):
                return "unexpected response from Anthropic (\(what))"
            }
        }
    }

    static func begin() -> Pending {
        let verifier = randomURLSafe(bytes: 32)
        let state = randomURLSafe(bytes: 32)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            // Asks the page to *display* the code instead of redirecting with it.
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return Pending(verifier: verifier, state: state, url: components.url!)
    }

    /// Trades the pasted code for a credential blob in Claude Code's own format.
    ///
    /// - Parameter diagnosticsDirectory: the raw response is written here before
    ///   it is interpreted. The response shape is the one thing in this file that
    ///   could not be verified against a live call beforehand, so when a field
    ///   moves, the bytes that prove it are already on disk instead of having to
    ///   reproduce the failure.
    static func exchange(
        pasted: String,
        pending: Pending,
        diagnosticsDirectory: URL? = nil,
        session: URLSession = .shared
    ) async throws -> (credentials: Credentials, identity: Identity?) {
        // The page presents the code as `code#state`. Accept either form: pasting
        // the whole thing is what people actually do.
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FlowError.noCode }
        let parts = trimmed.split(separator: "#", maxSplits: 1)
        let code = String(parts[0])
        let state = parts.count > 1 ? String(parts[1]) : pending.state

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Blank for the same reason `TokenRefresher` blanks it: this host 429s on
        // common default User-Agents.
        request.setValue("", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": pending.verifier,
        ])

        let (data, _) = try await session.data(for: request)

        if let directory = diagnosticsDirectory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            TokenRefresher.writeDurably(
                shapeRecord(of: data), to: directory.appending(path: ".authorize-raw.json"))
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FlowError.malformed("unparseable")
        }
        guard let accessToken = object["access_token"] as? String, !accessToken.isEmpty else {
            // Reuse the refresher's classifier so both paths describe the same
            // server errors the same way.
            switch TokenRefresher.classify(object) {
            case .rateLimited(let m), .needsLogin(let m), .failed(let m):
                throw FlowError.rejected(m)
            default:
                throw FlowError.malformed("no access_token")
            }
        }

        // Deliberately after the tokens are in hand, and deliberately unable to
        // throw. The plan tier is worth a round trip but it is not worth losing a
        // credential over: at this point the authorization code is already spent,
        // so a thrown error here would strand a token that cannot be minted again
        // without another sign-in.
        let profile = await profile(accessToken: accessToken, session: session)

        return (blob(from: object, accessToken: accessToken, profile: profile),
                profile ?? identity(from: object))
    }

    /// Asks who this token belongs to and what they are paying for.
    ///
    /// Returns nil rather than throwing on every failure path — see the call site
    /// in `exchange` for why. The account still saves; it just shows no plan until
    /// something asks again.
    static func profile(accessToken: String, session: URLSession = .shared) async -> Identity? {
        var request = URLRequest(url: profileURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(UsageClient.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Headroom/0.1 (macOS)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
        else { return nil }
        return identity(fromProfile: data)
    }

    /// Identity from the profile endpoint, which unlike the token response
    /// carries the organization's type and rate limit tier.
    ///
    /// Nil unless the account block is complete: a half-populated identity would
    /// overwrite a good email with nothing on the backfill path.
    static func identity(fromProfile data: Data) -> Identity? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["account"] as? [String: Any],
              let email = account["email"] as? String ?? account["email_address"] as? String,
              let uuid = account["uuid"] as? String
        else { return nil }

        let organization = root["organization"] as? [String: Any]
        return Identity(
            email: email,
            accountUUID: uuid,
            organizationUUID: organization?["uuid"] as? String,
            organizationType: organization?["organization_type"] as? String,
            rateLimitTier: organization?["rate_limit_tier"] as? String
        )
    }

    /// The response keys and their types, with every value discarded.
    ///
    /// This file used to hold the raw token response so the shape could be read
    /// off disk when a field moved. The shape is now known, and what was left was
    /// a live refresh token sitting in Application Support indefinitely. Keeping
    /// the keys keeps the diagnostic; dropping the values removes the liability.
    static func shapeRecord(of data: Data) -> Data {
        var lines: [String] = []
        func walk(_ object: [String: Any], prefix: String) {
            for key in object.keys.sorted() {
                let value = object[key]
                if let nested = value as? [String: Any] {
                    walk(nested, prefix: prefix + key + ".")
                } else {
                    lines.append("\(prefix)\(key): \(type(of: value ?? "nil"))")
                }
            }
        }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            walk(root, prefix: "")
        } else {
            lines.append("unparseable (\(data.count) bytes)")
        }
        let header = "# key shapes only — values are deliberately not recorded\n"
        return Data((header + lines.joined(separator: "\n") + "\n").utf8)
    }

    /// Builds the credential in the exact shape Claude Code stores, so a swap
    /// writes something it can read back without translation.
    ///
    /// - Parameter profile: the plan tier, which the token response does not
    ///   carry. Nil when the profile call failed, in which case the credential is
    ///   still complete — it just has no plan on it.
    static func blob(
        from object: [String: Any], accessToken: String, profile: Identity?
    ) -> Credentials {
        var oauth: [String: Any] = [
            "accessToken": accessToken,
            "clientId": clientID,
        ]

        if let refresh = object["refresh_token"] as? String { oauth["refreshToken"] = refresh }
        if let seconds = number(object["expires_in"]) {
            oauth["expiresAt"] = milliseconds(fromNow: seconds)
        }
        if let seconds = number(object["refresh_token_expires_in"]) {
            oauth["refreshTokenExpiresAt"] = milliseconds(fromNow: seconds)
        }

        // The granted scopes, not the requested ones -- the server is free to
        // narrow them, and storing what we asked for would hide that.
        if let granted = object["scope"] as? String {
            oauth["scopes"] = granted.split(separator: " ").map(String.init)
        } else {
            oauth["scopes"] = scopes
        }

        let organization = object["organization"] as? [String: Any]
        // Profile first: the token response has never carried either of these in
        // practice, but read it as a fallback so this keeps working if that
        // changes rather than silently preferring a stale source.
        if let type = profile?.organizationType
            ?? organization?["organization_type"] as? String {
            oauth["subscriptionType"] = type
                .replacingOccurrences(of: "claude_", with: "")
        }
        if let tier = profile?.rateLimitTier ?? organization?["rate_limit_tier"] as? String {
            oauth["rateLimitTier"] = tier
        }

        // Claude Code keeps this identity beside the tokens as well as in
        // ~/.claude.json. A newly authorised credential has not populated that
        // config yet, so dropping it here loses the only account UUID attached
        // to the token until Claude Code performs its next bootstrap.
        if let account = object["account"] as? [String: Any],
           let uuid = account["uuid"] as? String {
            var tokenAccount: [String: Any] = ["uuid": uuid]
            if let email = account["email_address"] as? String ?? account["email"] as? String {
                tokenAccount["emailAddress"] = email
            }
            if let organizationUUID = organization?["uuid"] as? String {
                tokenAccount["organizationUuid"] = organizationUUID
            }
            oauth["tokenAccount"] = tokenAccount
        }

        let raw = try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
        return Credentials(raw: raw)
    }

    /// Identity straight out of the token response, so a newly added account
    /// carries a real email instead of the placeholder name it was typed under.
    ///
    /// Carries no plan — the token response has no tier in it. `identity(fromProfile:)`
    /// is the one that does; this is the fallback when that call failed.
    static func identity(from object: [String: Any]) -> Identity? {
        guard let account = object["account"] as? [String: Any],
              let email = account["email_address"] as? String ?? account["email"] as? String,
              let uuid = account["uuid"] as? String
        else { return nil }

        let organization = object["organization"] as? [String: Any]
        return Identity(
            email: email,
            accountUUID: uuid,
            organizationUUID: organization?["uuid"] as? String,
            organizationType: organization?["organization_type"] as? String,
            rateLimitTier: organization?["rate_limit_tier"] as? String
        )
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? Double) ?? (value as? Int).map(Double.init)
    }

    private static func milliseconds(fromNow seconds: Double) -> Double {
        Date().addingTimeInterval(seconds).timeIntervalSince1970 * 1000
    }

    // MARK: PKCE

    private static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        // A predictable verifier defeats the point of PKCE, so this is the system
        // CSPRNG rather than `Int.random`.
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
