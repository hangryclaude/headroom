import Foundation

struct StoredAccount: Codable, Identifiable, Equatable {
    var name: String
    var email: String?
    var plan: String?
    /// The raw tier, e.g. `default_claude_max_20x`, kept alongside the humanised
    /// `plan` label because pricing has to key off something stable. The label is
    /// for reading; this is for arithmetic. Optional so existing vault files
    /// decode unchanged and fill in on the next identity refresh.
    var rateLimitTier: String?
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
    case refreshInFlight(String)

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
        case .refreshInFlight(let n):
            return "a token refresh for \(n) is in flight — try again in a moment"
        }
    }
}

/// The one surface a swap installs a credential onto.
///
/// Exists so `activate` can be exercised without a real Keychain. It had no
/// tests at all, which is how the post-swap identity bug reached a user: the
/// suite reported every check passing while the swap engine -- the part that can
/// destroy an account -- was never run. Anything that overwrites the only copy
/// of a live OAuth token deserves a harness that does not need the user's own
/// token to run.
protocol CredentialStore: Sendable {
    func exists() -> Bool
    func modifiedAt() -> Date?
    func read(allowInteraction: Bool) throws -> Data
    func write(_ data: Data, allowInteraction: Bool) throws
}

/// The real one. A thin shim, so the seam costs nothing in production.
struct KeychainStore: CredentialStore {
    func exists() -> Bool { Keychain.exists() }
    func modifiedAt() -> Date? { Keychain.modifiedAt() }
    func read(allowInteraction: Bool) throws -> Data {
        try Keychain.read(allowInteraction: allowInteraction)
    }
    func write(_ data: Data, allowInteraction: Bool) throws {
        try Keychain.write(data, allowInteraction: allowInteraction)
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
    private let store: CredentialStore

    init(root: URL = ClaudePaths.support.appending(path: "vault"),
         guardian: SessionGuard = SessionGuard(),
         identityURL: URL = ClaudePaths.configJSON,
         store: CredentialStore = KeychainStore()) {
        self.root = root
        self.indexURL = root.appending(path: "accounts.json")
        self.guardian = guardian
        self.identityURL = identityURL
        self.store = store
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
        guard !stored.isEmpty, let name = resolvedActiveName(among: stored) else { return nil }
        return stored.first { $0.name == name }
    }

    /// True when this stored account is the one currently signed in.
    private func isActive(_ account: StoredAccount) -> Bool {
        resolvedActiveName(among: accounts()) == account.name
    }

    /// Which account is installed right now, answered without depending solely
    /// on a key this class deletes.
    ///
    /// `repointConfig` clears `oauthAccount` at the end of every swap, on
    /// purpose: a cleared cache refetches correctly where a restored stale one
    /// stays wrong forever. But identity used to be read *only* from that key,
    /// so for the whole window between a swap and Claude Code's next launch,
    /// Headroom believed no account was installed. That was not cosmetic. The
    /// forced usage refresh that follows a swap skips "the active account", so
    /// with nothing active it reached for the account just installed, found the
    /// vault's copy of its token expired -- which is usually *why* you switch to
    /// a dormant account -- and redeemed the refresh token. The rotated pair went
    /// to the vault file only, leaving the Keychain holding a refresh token the
    /// server had already consumed. The account broke on next use and asked to
    /// sign in again, which reads to the user as "the swap didn't work".
    ///
    /// The marker written at swap time settles it. Its authority rests on the
    /// Keychain's own modification date: if the item has not been rewritten since
    /// Headroom installed a token into it, then that token is still what is
    /// installed, and no cache anywhere can argue. The moment anything else
    /// writes the item -- Claude Code rotating a token, or a fresh `claude login`
    /// -- the date moves, the marker stops being evidence, and `oauthAccount`
    /// takes over as it should, because by then Claude Code has run and written
    /// it. Reading a modification date is an attribute read, so this stays free
    /// and cannot raise a dialog.
    private func resolvedActiveName(among stored: [StoredAccount]) -> String? {
        let marker = activeMarker().flatMap { marker in
            stored.contains { $0.name == marker.name } ? marker : nil
        }
        // Bound separately: `read()?.accountUUID.flatMap` would apply the chain's
        // flatMap to the unwrapped String, not to the Optional.
        let configUUID = IdentityReader(configURL: identityURL).read()?.accountUUID
        let fromConfig = configUUID.flatMap { uuid in
            stored.first { $0.accountUUID == uuid }?.name
        }

        guard let marker else { return fromConfig }
        guard let fromConfig else {
            // Nothing else has an opinion, so the marker's name stands even if
            // the Keychain has been written since. What a later write changes is
            // the *token*, not which account is installed -- Claude Code
            // refreshing a token rotates it in place for the same account.
            // Requiring a matching date here reopened the original bug in a
            // narrower window: a rotation that lands before Claude Code writes
            // `oauthAccount` back would leave nobody able to name the installed
            // account, and the outgoing re-snapshot would be skipped again.
            return marker.name
        }
        // Both have an opinion, so they can disagree -- a long-running Claude
        // Code process can rewrite the config from a stale in-memory cache and
        // put the previous account back. The marker wins for exactly as long as
        // the Keychain still holds what Headroom put there; once anything else
        // has written the item, Claude Code's record is the better evidence.
        return marker.keychainModifiedAt == store.modifiedAt() ? marker.name : fromConfig
    }

    /// The account Headroom last installed, and the Keychain modification date
    /// that write produced. Only meaningful while the two still agree.
    private struct ActiveMarker: Codable {
        var name: String
        var keychainModifiedAt: Date?
    }

    private var activeMarkerURL: URL { root.appending(path: "active.json") }

    private func activeMarker() -> ActiveMarker? {
        guard let data = FileManager.default.contents(atPath: activeMarkerURL.path) else {
            return nil
        }
        return try? JSONDecoder().decode(ActiveMarker.self, from: data)
    }

    /// Recorded immediately after the Keychain write and before anything else
    /// that can fail, so a swap that stumbles later is still attributed to the
    /// account actually installed.
    ///
    /// Not private so that `--selftest` can drive it against a temporary vault:
    /// the alternative is hand-encoding the marker in the test, which would let
    /// the format drift out from under the thing it is meant to be proving.
    func recordActive(_ name: String) {
        let marker = ActiveMarker(name: name, keychainModifiedAt: store.modifiedAt())
        guard let data = try? JSONEncoder().encode(marker) else { return }
        try? data.write(to: activeMarkerURL, options: .atomic)
    }

    // MARK: Credentials

    private func currentCredentials(allowInteraction: Bool = true) throws -> Credentials {
        Credentials(raw: try store.read(allowInteraction: allowInteraction))
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

    /// The mutex `TokenRefresher` holds while it redeems this account's refresh
    /// token. `activate` takes the same one, so a swap and a refresh of the same
    /// account can never interleave.
    func refreshLock(for name: String) -> URL {
        root.appending(path: name).appending(path: TokenRefresher.lockFileName)
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
    ///
    /// **This can block.** Reading the live credential goes through the Keychain,
    /// which raises a macOS authorisation dialog the first time each build asks --
    /// and the grant is tied to the binary, so every rebuild re-prompts. Fine for
    /// a swap, where the user initiated something and a fresh token is the whole
    /// point. Use `storedAccessToken` anywhere that must not stall.
    func accessToken(for account: StoredAccount) -> String? {
        credentials(for: account)?.accessToken
    }

    /// Access token from the vault's own copy, never the Keychain.
    ///
    /// Read-only reporting commands use this deliberately. A command whose entire
    /// job is printing a table must never block on a modal dialog the user may
    /// not even be looking at -- and it did, once, which is why this exists. The
    /// cost is that the active account's copy can be older than the live one, so
    /// a stale token reports as unreachable rather than silently prompting.
    func storedAccessToken(for account: StoredAccount) -> String? {
        storedCredentials(account.name)?.accessToken
    }

    /// Fills in an account's email, plan, and UUID without touching its tokens.
    ///
    /// This is the repair path for accounts added before the sign-in flow asked
    /// the profile endpoint for a plan tier: those were stored with no plan at
    /// all, and re-logging in four accounts to fix a label would be an absurd
    /// price. The credential is not read or rewritten, so the fingerprint stays
    /// put and there is no way for this to disturb a token.
    ///
    /// - Returns: false when another account already holds this UUID. That is a
    ///   refusal, not a failure — writing it would leave two slots claiming one
    ///   account, which is exactly the confusion that got a live account's
    ///   consumed refresh token replayed. The caller reports it; nothing changes.
    func updateIdentity(_ identity: Identity, for name: String) throws -> Bool {
        var list = accounts()
        guard let index = list.firstIndex(where: { $0.name == name }) else {
            throw VaultError.unknownAccount(name)
        }
        if list.contains(where: { $0.accountUUID == identity.accountUUID && $0.name != name }) {
            return false
        }

        list[index].email = identity.email
        list[index].plan = identity.planLabel
        list[index].rateLimitTier = identity.rateLimitTier
        list[index].accountUUID = identity.accountUUID
        try write(list)
        return true
    }

    // MARK: Capture

    /// Saves whatever is signed in right now as a named account.
    @discardableResult
    func capture(as name: String) throws -> StoredAccount {
        let credentials = try currentCredentials()
        guard credentials.accessToken != nil else { throw VaultError.noCredentials }

        let identity = IdentityReader(configURL: identityURL).read()
        var list = accounts()

        // `oauthAccount` is missing for the whole window between a swap and
        // Claude Code's next launch, because this class clears it. A capture made
        // in that window used to store an entry with no UUID at all -- which the
        // duplicate guard below cannot compare and `activeAccount` can never
        // match again, so the slot stayed unidentifiable for good. The marker
        // already knows which account is installed; use it.
        let installed = identity == nil
            ? list.first { $0.name == resolvedActiveName(among: list) }
            : nil
        let accountUUID = identity?.accountUUID ?? installed?.accountUUID
        let email = identity?.email ?? installed?.email
        let planLabel = identity?.planLabel ?? installed?.plan
        let rateLimitTier = identity?.rateLimitTier ?? installed?.rateLimitTier

        // Refuse to store the same account twice under different names.
        //
        // Without this, a sign-in that never completed silently saves the
        // *current* credential again, and the vault grows a phantom account that
        // looks switchable but shares a UUID with the real one. Switching to it
        // is a no-op, and the policy sees two entries where there is one login.
        if let accountUUID,
           let clash = list.first(where: { $0.accountUUID == accountUUID && $0.name != name }) {
            throw VaultError.duplicateAccount(
                existing: clash.name, email: email ?? accountUUID)
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
            email: email,
            plan: planLabel,
            rateLimitTier: rateLimitTier,
            accountUUID: accountUUID,
            fingerprint: credentials.fingerprint,
            savedAt: Date(),
            lastActiveAt: Date()
        )

        try persist(credentials, for: name)
        list.append(account)
        try write(list)
        // Capturing does not change which account is installed, but it does
        // change its name, and the marker points at a name.
        recordActive(name)
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
            rateLimitTier: identity?.rateLimitTier,
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
    func activate(
        _ name: String, force: Bool = false, allowKeychainPrompt: Bool = true
    ) throws -> StoredAccount {
        var list = accounts()
        guard let targetIndex = list.firstIndex(where: { $0.name == name }) else {
            throw VaultError.unknownAccount(name)
        }

        let verdict = guardian.verdict()
        if verdict.blocksManualSwitch && !force {
            throw VaultError.sessionsBusy(verdict.sessions)
        }

        // Hold the target's refresh mutex for the whole swap. Without it, a
        // background refresh of the dormant account could be mid-redemption
        // while its *pre-rotation* blob is read below and installed into the
        // Keychain; the rotated pair then lands in the vault file only, and
        // Claude Code is left holding a refresh token the server has already
        // consumed -- which revokes the account rather than logging it out.
        // The lock is a file, so this also covers the CLI swapping while the
        // menu bar app is refreshing, which no in-process flag can see.
        let targetLock = refreshLock(for: name)
        guard let targetOwnership = TokenRefresher.acquireLock(targetLock) else {
            throw VaultError.refreshInFlight(name)
        }
        defer { TokenRefresher.releaseLock(targetLock, ownership: targetOwnership) }

        guard let target = storedCredentials(name), target.accessToken != nil else {
            throw VaultError.noCredentials
        }

        // The identity cache can outlive the Keychain item. This happens after a
        // broken ACL is repaired by removing the inaccessible item: the account
        // still looks active by UUID, but Claude has no credential to read. In
        // that state there is no outgoing secret to preserve, so restore the
        // selected vault copy directly instead of reporting "already active" or
        // trying to read an item that does not exist.
        if !store.exists() {
            try store.write(target.raw, allowInteraction: allowKeychainPrompt)
            recordActive(name)
            try Self.repointConfig(at: identityURL)

            list[targetIndex].lastActiveAt = Date()
            list[targetIndex].fingerprint = target.fingerprint
            try write(list)
            return list[targetIndex]
        }

        if isActive(list[targetIndex]) { throw VaultError.alreadyActive(name) }

        // Same mutex for the outgoing side, taken before its live credential is
        // read so the snapshot persisted below cannot be overtaken by a rotation
        // that started a moment earlier. Resolved here, ahead of the read, for
        // that reason; the name is a pure function of the vault files.
        let currentName = resolvedActiveName(among: list)
        var outgoingLock: (url: URL, ownership: String)?
        if let currentName, currentName != name,
           list.contains(where: { $0.name == currentName }) {
            let url = refreshLock(for: currentName)
            guard let ownership = TokenRefresher.acquireLock(url) else {
                throw VaultError.refreshInFlight(currentName)
            }
            outgoingLock = (url, ownership)
        }
        defer {
            if let outgoingLock {
                TokenRefresher.releaseLock(outgoingLock.url, ownership: outgoingLock.ownership)
            }
        }

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
            live = try currentCredentials(allowInteraction: allowKeychainPrompt)
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
        //
        // Resolved through the marker rather than straight off `oauthAccount`,
        // because this block was skipped entirely on any second swap made before
        // Claude Code relaunched: the previous swap had deleted that key, so the
        // outgoing account matched nothing and its live credential was written
        // only into a dated backup directory nobody looks in. Rule 1 exists to
        // stop exactly the loss that then followed.
        if let outgoingIndex = list.firstIndex(where: { $0.name == currentName }) {
            try persist(live, for: list[outgoingIndex].name)
            list[outgoingIndex].fingerprint = live.fingerprint
            list[outgoingIndex].lastActiveAt = Date()
            if let snapshot = try? QuotaReader().read() {
                list[outgoingIndex].lastSessionPercent = snapshot.session?.reading.percent
                list[outgoingIndex].lastWeeklyPercent = snapshot.weekly?.reading.percent
                list[outgoingIndex].usageFetchedAt = snapshot.fetchedAt
            }
            try write(list)
        } else {
            // Signed in to something we have never saved. Its credential is about
            // to be overwritten and would be gone for good, so park a copy under
            // a reserved name rather than discarding it.
            //
            // No longer conditional on knowing *who* it is. The guard used to
            // require a readable identity, so the one case where the account is
            // genuinely unidentifiable -- the case where a parked copy is the
            // only remaining record of it -- was the case that skipped parking.
            try persist(live, for: Self.unsavedSlot)
        }

        // Clear the identity cache *before* installing the token, so that a
        // failure at either step reports itself truthfully.
        //
        // The other order lies in the direction that costs the most. If the
        // Keychain write lands and this then throws, the swap has happened --
        // Claude Code is running as the new account -- but `activate` throws, so
        // the user is told it failed and reasonably tries again. This way round,
        // a failure here means nothing has been installed yet and "it failed" is
        // the truth; and if the write fails afterwards, the only damage is a
        // cleared cache in front of an unchanged token, which Claude Code
        // repopulates correctly on its next launch.
        try Self.repointConfig(at: identityURL)

        try store.write(target.raw, allowInteraction: allowKeychainPrompt)
        recordActive(name)

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

    /// Backups sit beside the vault, not at a fixed absolute path.
    ///
    /// Derived from `root` so that a vault pointed at a temporary directory is
    /// genuinely self-contained. It was not: `--selftest` exercising the swap
    /// engine wrote backup directories into the real Application Support folder,
    /// which is the same mistake as `repointConfig` reaching past its injected
    /// URL to the live `~/.claude.json`. In production `root` is
    /// `support/vault`, so this resolves to `support/backups` exactly as before.
    private var backupRoot: URL {
        root.deletingLastPathComponent().appending(path: "backups")
    }

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
        let directory = backupRoot
            .appending(path: "\(stamp)-\(UUID().uuidString.prefix(8))")
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
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: backupRoot, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let sorted = entries.sorted {
            ($0.lastPathComponent) > ($1.lastPathComponent)
        }
        for stale in sorted.dropFirst(Self.backupsKept) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    static let backupsKept = 20
}
