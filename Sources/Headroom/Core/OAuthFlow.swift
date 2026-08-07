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
                data, to: directory.appending(path: ".authorize-raw.json"))
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

        return (blob(from: object, accessToken: accessToken), identity(from: object))
    }

    /// Builds the credential in the exact shape Claude Code stores, so a swap
    /// writes something it can read back without translation.
    private static func blob(from object: [String: Any], accessToken: String) -> Credentials {
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
        if let type = organization?["organization_type"] as? String {
            oauth["subscriptionType"] = type
                .replacingOccurrences(of: "claude_", with: "")
        }
        if let tier = organization?["rate_limit_tier"] as? String {
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
    private static func identity(from object: [String: Any]) -> Identity? {
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
