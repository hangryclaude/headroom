import Foundation

/// Where the Devin API key lives, and what is deliberately not secret.
///
/// The key goes in the login Keychain under its own service, reusing the generic
/// `Keychain` helpers rather than a second implementation. The org id does *not*:
/// it is an account identifier that appears in URLs, so putting it behind a
/// Keychain prompt would mean a confidential-information dialog every launch to
/// protect something already visible in the browser address bar.
///
/// The allowance is the same kind of thing — a number the user reads off their
/// plan page. No endpoint reports it, which is the whole reason it is config.
enum DevinCredentials {
    static let keychainService = "ai.devin.api"

    private static let orgKey = "DevinOrgID"
    private static let allowanceKey = "DevinACUAllowance"

    /// Named explicitly rather than `.standard`, because these values are written
    /// by the CLI and read by the app bundle.
    ///
    /// `UserDefaults.standard` keys its domain off the running process: the
    /// bundle gets `com.angus.headroom`, the bare `Headroom` binary gets
    /// `Headroom`. Verified, not assumed — `--devin org` written by the CLI was
    /// invisible to the app until this suite existed. `Settings` has the same
    /// latent split but nothing sets it from the command line, so it never bit.
    /// Computed rather than stored: a `UserDefaults` in a `static let` is not
    /// Sendable, and the lookup is a cheap cached call anyway.
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: "com.angus.headroom") ?? .standard
    }

    // MARK: Key

    /// Whether a key is stored, checked without reading it — so launching
    /// Headroom never triggers the Keychain prompt on its own.
    static var hasKey: Bool {
        Keychain.exists(service: keychainService, account: Keychain.defaultAccount)
    }

    static func readKey(allowInteraction: Bool = true) throws -> String {
        let data = try Keychain.read(service: keychainService,
                                     account: Keychain.defaultAccount,
                                     allowInteraction: allowInteraction)
        guard let key = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
        else { throw DevinClient.Failure.noKey }
        return key
    }

    static func writeKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DevinClient.Failure.noKey }
        try Keychain.write(Data(trimmed.utf8),
                           service: keychainService,
                           account: Keychain.defaultAccount)
    }

    static func clearKey() throws {
        // Overwrite rather than delete: SecItemDelete on a missing item is an
        // error, and an empty value already reads as unconfigured everywhere.
        try Keychain.write(Data(), service: keychainService, account: Keychain.defaultAccount)
    }

    // MARK: Org and allowance

    static var orgID: String? {
        get {
            defaults.string(forKey: orgKey).flatMap { $0.isEmpty ? nil : $0 }
        }
        set { defaults.set(newValue, forKey: orgKey) }
    }

    /// ACUs the plan includes per period, or nil when the user has not said.
    static var allowance: Double? {
        get {
            let stored = defaults.double(forKey: allowanceKey)
            return stored > 0 ? stored : nil
        }
        set { defaults.set(newValue ?? 0, forKey: allowanceKey) }
    }

    /// Configured enough to attempt a fetch. A key without an org id is useless,
    /// and the section should stay hidden rather than show a permanent error.
    static var isConfigured: Bool { hasKey && orgID != nil }
}
