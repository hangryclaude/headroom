import Foundation

struct StoredAccount: Codable, Identifiable, Equatable {
    var name: String
    var email: String?
    var plan: String?
    var accountUUID: String?
    /// SHA-256 over the access + refresh tokens. Identifies which vault slot is
    /// currently installed without keeping a pointer that can desync.
    var fingerprint: String
    var savedAt: Date
    var lastActiveAt: Date?
    /// Last usage seen for this account, so an inactive one shows a real figure
    /// with an age rather than a blank.
    var lastSessionPercent: Int?
    var lastWeeklyPercent: Int?
    var usageFetchedAt: Date?

    var id: String { name }
    var label: String { email ?? name }
}

enum VaultError: Error, CustomStringConvertible {
    case sessionsBusy([LiveSession])
    case unknownAccount(String)
    case alreadyActive(String)
    case noCredentials
    case cannotReadOutgoing(String)
    case duplicateAccount(existing: String, email: String)

    var description: String {
        switch self {
        case .sessionsBusy(let s):
            let names = s.filter(\.isBusy).map(\.name).joined(separator: ", ")
            return "a session is mid-request: \(names)"
        case .unknownAccount(let n): return "no account named \(n)"
        case .alreadyActive(let n):  return "\(n) is already active"
        case .noCredentials:         return "nothing signed in to save"
        case .duplicateAccount(let existing, let email):
            return "\(email) is already saved as \(existing) — sign in to a different "
                 + "account first, then save that one"
        case .cannotReadOutgoing(let why):
            // Never overwrite a credential we could not first save a copy of.
            return "refusing to swap — cannot read the current account (\(why))"
        }
    }
}

/// Stores Claude accounts and swaps between them.
///
/// Two rules here are not preferences, they are the difference between working
/// and destroying an account:
///
/// 1. **Re-snapshot before switching away.** Anthropic rotates the refresh token
///    on every redemption, in place. The copy sitting in the vault from the last
///    swap is therefore stale the moment the account is used, and replaying a
///    consumed refresh token trips reuse detection and revokes the entire token
///    family -- the account is dead, not merely logged out. Both of the prior
///    tools that touched this learned it the hard way (caam's `ResnapshotOutgoing`
///    exists for exactly this; an account was burned this way on 2026-07-08
///    when two processes redeemed the same token). So the outgoing
///    account's *live* credentials are re-captured on every single swap.
///
/// 2. **Never write while a request is in flight.** Claude Code may be mid-refresh,
///    and a swap landing between the server rotating and Claude Code persisting
///    loses the new token permanently.
///
/// Vault lives under Headroom's own Application Support rather than inside caam's
/// directory. Writing another tool's state with a schema we have not verified
/// risks breaking a tool that currently works for Codex; exporting to caam later
/// is easy, un-corrupting it is not.
final class AccountVault: @unchecked Sendable {
    let root: URL
    private let indexURL: URL
    private let guardian: SessionGuard

    init(root: URL = ClaudePaths.support.appending(path: "vault"),
         guardian: SessionGuard = SessionGuard(),
         identityURL: URL = ClaudePaths.configJSON) {
        self.root = root
        self.indexURL = root.appending(path: "accounts.json")
        self.guardian = guardian
        self.identityURL = identityURL
    }

    /// Reserved slot for a signed-in account that was never saved, so its
    /// credential is not simply discarded by a swap.
    static let unsavedSlot = "_unsaved"

    /// Where identity is read from. Injectable so the swap logic can be tested.
    ///
    /// No in-memory mutable state anywhere in this class: every operation reads
    /// and writes files, so it is safe to hand across isolation boundaries. That
    /// matters because the refresher persists through a callback from a
    /// non-isolated context.
    private let identityURL: URL

    // MARK: Index

    func accounts() -> [StoredAccount] {
        guard let data = FileManager.default.contents(atPath: indexURL.path),
              let list = try? JSONDecoder().decode([StoredAccount].self, from: data)
        else { return [] }
        return list.sorted { $0.savedAt < $1.savedAt }
    }

    private func write(_ accounts: [StoredAccount]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(accounts)
        try data.write(to: indexURL, options: .atomic)
    }

    /// Which stored account is installed right now.
    ///
    /// Matched on `oauthAccount.accountUuid` from `~/.claude.json`, **not** on a
    /// hash of the credential. That distinction is load-bearing and was got wrong
    /// first time round: Claude Code rotates the token in place every few hours,
    /// which changes any fingerprint taken over it. An account identified that
    /// way stops being recognisable the moment it is used, and the consequences
    /// compound -- the live account gets treated as inactive, so the usage poll
    /// reaches for the vault's *stale* blob and redeems a refresh token the
    /// server has already consumed, which revokes the whole token family and
    /// kills the account.
    ///
    /// The account UUID does not rotate. It also costs nothing: it is read from a
    /// plain JSON file rather than the Keychain, so identifying the active
    /// account never raises an authorisation dialog.
    func activeAccount() -> StoredAccount? {
        let stored = accounts()
        guard !stored.isEmpty, let uuid = IdentityReader(configURL: identityURL).read()?.accountUUID
        else { return nil }
        return stored.first { $0.accountUUID == uuid }
    }

    /// True when this stored account is the one currently signed in.
    private func isActive(_ account: StoredAccount) -> Bool {
        guard let uuid = account.accountUUID else { return false }
        return IdentityReader(configURL: identityURL).read()?.accountUUID == uuid
    }

    // MARK: Credentials

    private func currentCredentials() throws -> Credentials {
        Credentials(raw: try Keychain.read())
    }

    private func credentialURL(_ name: String) -> URL {
        root.appending(path: name).appending(path: "credentials.json")
    }

    private func storedCredentials(_ name: String) -> Credentials? {
        guard let data = FileManager.default.contents(atPath: credentialURL(name).path)
        else { return nil }
        return Credentials(raw: data)
    }

    /// This account's vault directory, which is also where the refresher keeps
    /// its lock, its pre-call backup, and the raw rotated response.
    func directory(for account: StoredAccount) -> URL {
        root.appending(path: account.name)
    }

    /// The stored blob. The active account is read live instead, so a token
    /// Claude Code just rotated wins over the vault's older copy.
    ///
    /// Liveness is decided by account UUID before the Keychain is touched: it is
    /// both free and rotation-proof, where a fingerprint comparison would fall
    /// through to the vault's stale blob after every routine rotation.
    func credentials(for account: StoredAccount) -> Credentials? {
        if isActive(account), let live = try? currentCredentials() {
            return live
        }
        return storedCredentials(account.name)
    }

    /// Writes a rotated token set back, and moves the fingerprint with it.
    ///
    /// The fingerprint has to follow: it is hashed over the access and refresh
    /// tokens, both of which the server just replaced, so leaving it stale would
    /// make the account unidentifiable the next time we look for which slot is
    /// installed.
    func replaceCredentials(_ credentials: Credentials, for account: StoredAccount) throws {
        try persist(credentials, for: account.name)
        var list = accounts()
        guard let index = list.firstIndex(where: { $0.name == account.name }) else { return }
        list[index].fingerprint = credentials.fingerprint
        try write(list)
    }

    /// Access token for an account, for the usage endpoint. The active account is
    /// read live so a token Claude Code just refreshed is used rather than the
    /// vault's older copy.
    func accessToken(for account: StoredAccount) -> String? {
        credentials(for: account)?.accessToken
    }

    // MARK: Capture

    /// Saves whatever is signed in right now as a named account.
    @discardableResult
    func capture(as name: String) throws -> StoredAccount {
        let credentials = try currentCredentials()
        guard credentials.accessToken != nil else { throw VaultError.noCredentials }

        let identity = IdentityReader(configURL: identityURL).read()
        var list = accounts()

        // Refuse to store the same account twice under different names.
        //
        // Without this, a sign-in that never completed silently saves the
        // *current* credential again, and the vault grows a phantom account that
        // looks switchable but shares a UUID with the real one. Switching to it
        // is a no-op, and the policy sees two entries where there is one login.
        if let uuid = identity?.accountUUID,
           let clash = list.first(where: { $0.accountUUID == uuid && $0.name != name }) {
            throw VaultError.duplicateAccount(
                existing: clash.name, email: identity?.email ?? uuid)
        }

        // Saving over an existing name replaces that account's stored
        // credential. Keep the old one: if it was a different account, this file
        // is the only copy of its token.
        if let existing = storedCredentials(name) {
            try backup(existing.raw, named: "replaced-\(name)")
        }
        list.removeAll { $0.name == name }

        let account = StoredAccount(
            name: name,
            email: identity?.email,
            plan: identity?.planLabel,
            accountUUID: identity?.accountUUID,
            fingerprint: credentials.fingerprint,
            savedAt: Date(),
            lastActiveAt: Date()
        )

        try persist(credentials, for: name)
        list.append(account)
        try write(list)
        return account
    }

    /// Stores an account signed in by `OAuthFlow`, leaving the Keychain alone.
    ///
    /// `capture` reads whatever is currently installed, so it can only ever save
    /// the account you are already using. This is the other direction: the
    /// credential arrives from a browser sign-in that never touched the live
    /// session, so accounts two through four can be added while account one keeps
    /// working. Nothing here is activated -- adding is not switching.
    @discardableResult
    func adopt(_ credentials: Credentials, identity: Identity?, as name: String) throws -> StoredAccount {
        guard credentials.accessToken != nil else { throw VaultError.noCredentials }

        var list = accounts()

        // Same guard as `capture`, for the same reason: signing in as an account
        // that is already saved otherwise grows a second entry that shares a UUID
        // with the first, and switching to it does nothing.
        if let uuid = identity?.accountUUID,
           let clash = list.first(where: { $0.accountUUID == uuid && $0.name != name }) {
            throw VaultError.duplicateAccount(
                existing: clash.name, email: identity?.email ?? uuid)
        }

        if let existing = storedCredentials(name) {
            try backup(existing.raw, named: "replaced-\(name)")
        }
        list.removeAll { $0.name == name }

        let account = StoredAccount(
            name: name,
            email: identity?.email,
            plan: identity?.planLabel,
            accountUUID: identity?.accountUUID,
            fingerprint: credentials.fingerprint,
            savedAt: Date(),
            // Never activated, so it has no last-active time. Claiming one would
            // date a swap that did not happen.
            lastActiveAt: nil
        )

        try persist(credentials, for: name)
        list.append(account)
        try write(list)
        return account
    }

    private func persist(_ credentials: Credentials, for name: String) throws {
        let directory = root.appending(path: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try credentials.raw.write(to: credentialURL(name), options: .atomic)
        // The token set is a secret sitting on disk; keep it owner-only.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: credentialURL(name).path)
    }

    /// Removes a stored account.
    ///
    /// The credential file is moved to a backup rather than deleted: an account
    /// you meant to keep is unrecoverable otherwise, and the file is small.
    func forget(_ name: String) throws {
        var list = accounts()
        guard list.contains(where: { $0.name == name }) else {
            throw VaultError.unknownAccount(name)
        }
        if let stored = storedCredentials(name) {
            try backup(stored.raw, named: "forgotten-\(name)")
        }
        list.removeAll { $0.name == name }
        try write(list)
        try? FileManager.default.removeItem(at: root.appending(path: name))
    }

    // MARK: Swap

    /// Moves to `name`. Returns the account now installed.
    @discardableResult
    func activate(_ name: String, force: Bool = false) throws -> StoredAccount {
        var list = accounts()
        guard let targetIndex = list.firstIndex(where: { $0.name == name }) else {
            throw VaultError.unknownAccount(name)
        }

        let verdict = guardian.verdict()
        if verdict.blocksManualSwitch && !force {
            throw VaultError.sessionsBusy(verdict.sessions)
        }

        guard let target = storedCredentials(name), target.accessToken != nil else {
            throw VaultError.noCredentials
        }

        if isActive(list[targetIndex]) { throw VaultError.alreadyActive(name) }

        // Read the outgoing credential up front, and refuse the swap if it
        // cannot be read.
        //
        // Overwriting the Keychain is destructive and there is exactly one copy
        // of the outgoing account's live token. `try?` here previously swallowed
        // a denied authorisation dialog, a locked screen, and every other
        // Keychain failure, then went on to overwrite anyway -- destroying an
        // account because a modal was dismissed. If we cannot save it, we do not
        // get to replace it.
        let live: Credentials
        do {
            live = try currentCredentials()
        } catch {
            throw VaultError.cannotReadOutgoing(String(describing: error))
        }

        try backupEverything(live)

        // Rule 1: re-capture the outgoing account before overwriting it. Its
        // refresh token has almost certainly been rotated since it was stored,
        // so the copy already in the vault is stale and would be a dead account
        // next time.
        //
        // The outgoing account is found by UUID, not by fingerprint. Matching on
        // the fingerprint meant this whole block was skipped precisely when it
        // mattered -- after Claude Code had rotated the token, which is the case
        // that makes the vault copy stale in the first place.
        let currentUUID = IdentityReader(configURL: identityURL).read()?.accountUUID
        if let currentUUID,
           let outgoingIndex = list.firstIndex(where: { $0.accountUUID == currentUUID }) {
            try persist(live, for: list[outgoingIndex].name)
            list[outgoingIndex].fingerprint = live.fingerprint
            list[outgoingIndex].lastActiveAt = Date()
            if let snapshot = try? QuotaReader().read() {
                list[outgoingIndex].lastSessionPercent = snapshot.session?.reading.percent
                list[outgoingIndex].lastWeeklyPercent = snapshot.weekly?.reading.percent
                list[outgoingIndex].usageFetchedAt = snapshot.fetchedAt
            }
            try write(list)
        } else if currentUUID != nil {
            // Signed in to something we have never saved. Its credential is about
            // to be overwritten and would be gone for good, so park a copy under
            // a reserved name rather than discarding it.
            try persist(live, for: Self.unsavedSlot)
        }

        try Keychain.write(target.raw)
        try Self.repointConfig()

        list[targetIndex].lastActiveAt = Date()
        list[targetIndex].fingerprint = target.fingerprint
        try write(list)

        return list[targetIndex]
    }

    /// Rewrites only the account-coupled keys of `~/.claude.json`.
    ///
    /// caam copies the whole file, which takes `projects`, `mcpServers`, and
    /// `numStartups` along with the identity -- your per-project history follows
    /// whichever account you last used. Headroom edits in place instead.
    ///
    /// Identity keys are *cleared*, not restored from a snapshot. Claude Code
    /// rewrites them from the token on next launch, and a cleared cache refetches
    /// correctly whereas a restored stale one stays wrong forever. The entitlement
    /// caches get the same treatment for the same reason.
    /// Takes the file URL so the surgery can be exercised against a copy in
    /// `--selftest`. Destroying `projects` or `mcpServers` here would be silent
    /// and unrecoverable, which makes it worth testing on something disposable.
    @discardableResult
    static func repointConfig(at url: URL = ClaudePaths.configJSON) throws -> Bool {
        guard let data = FileManager.default.contents(atPath: url.path),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }

        for key in accountCoupledKeys { root.removeValue(forKey: key) }

        let updated = try JSONSerialization.data(withJSONObject: root, options: [])
        try updated.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    /// Everything in `~/.claude.json` that belongs to one account rather than to
    /// this machine. Enumerated from the live file; the entitlement caches matter
    /// as much as the identity, since a stale `modelAccessCache` silently offers
    /// models the new account may not have.
    static let accountCoupledKeys = [
        "oauthAccount",
        "userID",
        "cachedUsageUtilization",
        "modelAccessCache",
        "passesEligibilityCache",
        "cachedExtraUsageDisabledReason",
        "orgModelDefaultCache",
        "additionalModelCostsCache",
        "additionalModelOptionsCache",
    ]

    // MARK: Backups

    /// Timestamped copies of both surfaces before anything is written. Cheap, and
    /// the one thing that makes a bad swap recoverable.
    private func backupEverything(_ live: Credentials) throws {
        let directory = try newBackupDirectory()
        try write(live.raw, to: directory.appending(path: "credentials.json"))
        if let config = FileManager.default.contents(atPath: ClaudePaths.configJSON.path) {
            try write(config, to: directory.appending(path: "claude.json"))
        }
        pruneBackups()
    }

    private func backup(_ data: Data, named name: String) throws {
        let directory = try newBackupDirectory()
        try write(data, to: directory.appending(path: "\(name).json"))
        pruneBackups()
    }

    /// Second-resolution timestamps collide when two swaps land in the same
    /// second, and the second one would silently overwrite the first backup.
    private func newBackupDirectory() throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let directory = ClaudePaths.support
            .appending(path: "backups/\(stamp)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    /// These files are live OAuth tokens, so they get the same owner-only
    /// treatment as the vault rather than the default umask.
    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Unbounded backups of credentials are a growing liability, not a safety
    /// net. Keep enough to recover from a bad swap, discard the rest.
    private func pruneBackups() {
        let root = ClaudePaths.support.appending(path: "backups")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let sorted = entries.sorted {
            ($0.lastPathComponent) > ($1.lastPathComponent)
        }
        for stale in sorted.dropFirst(Self.backupsKept) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    static let backupsKept = 20
}
