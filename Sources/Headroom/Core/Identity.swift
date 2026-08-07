import Foundation

/// Who Claude Code currently thinks it is.
///
/// This is what lets Headroom label accounts with real emails and plan tiers.
/// caam cannot: it only ever sees the opaque credential blob, so its Claude
/// profiles are named `auto-20260806-141719`. The identity is not in the
/// credential at all -- it is sitting in plain JSON in `~/.claude.json`.
struct Identity: Equatable {
    let email: String
    let accountUUID: String
    let organizationUUID: String?
    /// e.g. `claude_max`
    let organizationType: String?
    /// e.g. `default_claude_max_20x`
    let rateLimitTier: String?

    /// `default_claude_max_20x` -> "Max 20x".
    ///
    /// Only the first word is capitalised: the rest are magnitudes like `20x`,
    /// which `.capitalized` would mangle into `20X`.
    var planLabel: String {
        guard var tier = rateLimitTier else {
            return organizationType?
                .replacingOccurrences(of: "_", with: " ")
                .capitalized ?? "—"
        }
        for prefix in ["default_", "claude_"] where tier.hasPrefix(prefix) {
            tier.removeFirst(prefix.count)
        }
        let words = tier.split(separator: "_").map(String.init)
        guard let first = words.first else { return tier }
        return ([first.capitalized] + words.dropFirst()).joined(separator: " ")
    }

    /// Short handle used when there is no room for a full address.
    var handle: String { String(email.split(separator: "@").first ?? "account") }
}

struct IdentityReader {
    let configURL: URL

    init(configURL: URL = ClaudePaths.configJSON) {
        self.configURL = configURL
    }

    func read() -> Identity? {
        guard let data = FileManager.default.contents(atPath: configURL.path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let o = root["oauthAccount"] as? [String: Any],
              let email = o["emailAddress"] as? String,
              let uuid = o["accountUuid"] as? String
        else { return nil }

        return Identity(
            email: email,
            accountUUID: uuid,
            organizationUUID: o["organizationUuid"] as? String,
            organizationType: o["organizationType"] as? String,
            rateLimitTier: o["organizationRateLimitTier"] as? String
        )
    }
}
