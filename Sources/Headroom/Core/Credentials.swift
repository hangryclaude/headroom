import CryptoKit
import Foundation

/// The OAuth token set Claude Code stores, kept as raw JSON.
///
/// Headroom never rewrites the contents -- it moves the blob verbatim. That is
/// deliberate: the token set is rotated by the server, and a tool that
/// re-serialises it risks dropping a field it did not know about.
struct Credentials: Equatable {
    let raw: Data

    var accessToken: String? { Self.extract(raw, keys: ["accessToken", "access_token"]) }
    var refreshToken: String? { Self.extract(raw, keys: ["refreshToken", "refresh_token"]) }

    var expiresAt: Date? {
        guard let ms = Self.extractNumber(raw, keys: ["expiresAt", "expires_at"]) else { return nil }
        // Seconds vs milliseconds: anything past year ~2200 in seconds is really ms.
        return Date(timeIntervalSince1970: ms > 1e11 ? ms / 1000 : ms)
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    /// Identifies *which account* this is, and nothing else.
    ///
    /// Only the access and refresh tokens are hashed; `expiresAt` is excluded so
    /// a clock field alone cannot move it.
    ///
    /// **This is not a stable account identity and must never be used as one.**
    /// The access token changes on every refresh, so the fingerprint changes with
    /// it — several times a day in normal use. It answers "is this byte-for-byte
    /// the credential I stored?", not "is this the same account". Identity comes
    /// from `oauthAccount.accountUuid` (see `AccountVault.activeAccount`).
    /// Confusing the two once meant the live account stopped being recognisable
    /// after a routine rotation, and its already-consumed refresh token got
    /// replayed — which revokes the whole token family.
    var fingerprint: String {
        var hasher = SHA256()
        hasher.update(data: Data((accessToken ?? "").utf8))
        hasher.update(data: Data((refreshToken ?? "").utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Walks the shapes this blob has actually taken.
    ///
    /// Claude Code has nested the token under `claudeAiOauth`, stored it as a
    /// bare `oauthToken` string, and used both snake and camel case for the leaf.
    /// Tolerating all of them is cheaper than being broken by the next rename.
    private static func extract(_ data: Data, keys: [String]) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        for container in candidates(root) {
            for key in keys {
                if let value = container[key] as? String, !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func extractNumber(_ data: Data, keys: [String]) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        for container in candidates(root) {
            for key in keys {
                if let value = container[key] as? Double { return value }
                if let value = container[key] as? Int { return Double(value) }
            }
        }
        return nil
    }

    private static func candidates(_ root: [String: Any]) -> [[String: Any]] {
        var out: [[String: Any]] = [root]
        for wrapper in ["claudeAiOauth", "oauthToken", "claude_ai_oauth"] {
            if let nested = root[wrapper] as? [String: Any] { out.append(nested) }
        }
        return out
    }
}
