import Foundation
import LocalAuthentication
import Security

/// The half of an account swap that caam cannot do on this machine.
///
/// Claude Code's native installer keeps the OAuth token set in the login
/// Keychain, not in `~/.claude/.credentials.json`. caam swaps accounts by
/// copying that file, so on a native install it has nothing to copy -- `caam
/// robot status` reports the file as required-but-missing and every profile
/// stays blocked. Reading and writing the Keychain item directly is the only
/// thing that actually moves the account.
///
/// One sharp edge worth stating: the item's `account` attribute is the *Unix
/// username*, not the Claude email. Every Claude account on the machine
/// therefore collides on this single item, which is why swapping has to be an
/// explicit stash-then-write rather than anything resembling a file move.
///
/// # Why nothing here depends on Headroom's own code identity
///
/// A keychain item's decrypt ACL names binaries. Whoever creates the item is
/// the only binary named, so a swap used to leave an item that Claude Code was
/// not allowed to read -- and the user got a login-password dialog on every
/// Claude Code start, forever. The obvious repair, adding Headroom to the ACL
/// as well, does not survive contact with reality: an ACL entry is matched
/// against a binary's designated requirement, `.build/release/Headroom` is
/// ad-hoc signed so its requirement is its code hash, and that hash changes on
/// every single rebuild. An ACL naming Headroom is stale the next time anyone
/// runs `swift build`.
///
/// So this file names exactly one binary -- `/usr/bin/security` -- and both
/// sides read through it. Claude Code already does (`security
/// find-generic-password -a "$USER" -w -s "Claude Code-credentials"`), which is
/// why that entry is mandatory rather than a choice. Headroom does the same in
/// `read`. Writes need no ACL membership at all: the encrypt authorisation is
/// open, so `SecItemUpdate` succeeds regardless of who is asking. The result
/// has no moving parts that a rebuild, a `.app`-versus-CLI difference, or a
/// change of signing identity can invalidate.
///
/// The honest cost: naming `/usr/bin/security` means any process running as
/// this user can read the token, because any process can exec `security`. That
/// is not a weakening -- Claude Code's own read path already requires it, so the
/// item is in that position no matter what Headroom does. It is confined to the
/// Claude credential for that reason; items Headroom alone owns, like the Devin
/// key, keep the default creator-only ACL, and `securityToolACL` is what draws
/// that line.
///
/// Every claim above is asserted by `SelfTest.keychainAccessControl`, which
/// proves them by running `/usr/bin/security` as a separate process against a
/// scratch keychain rather than by inspecting what this file wrote.
enum Keychain {

    enum Failure: Error, CustomStringConvertible {
        case notFound
        case denied
        case os(OSStatus)

        var description: String {
            switch self {
            case .notFound: return "no Claude credentials in the Keychain"
            case .denied:   return "Keychain access denied — grant Headroom access when macOS asks"
            case .os(let s):
                let message = SecCopyErrorMessageString(s, nil) as String? ?? "unknown"
                return "Keychain error \(s): \(message)"
            }
        }
    }

    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The Unix username, which is what Claude Code stores the item under.
    static var defaultAccount: String { NSUserName() }

    /// The binary Claude Code shells out to when it reads its own token.
    ///
    /// Claude Code does not link the Security framework for this; it runs the
    /// `security` command line tool. That is why the prompt users see names
    /// *security* rather than *Claude*, and why trusting the Claude binary would
    /// not silence it.
    static let claudeCodeReaderPath = "/usr/bin/security"

    /// Long enough that a loaded machine does not report a false failure, short
    /// enough that a headless `--render` cannot be wedged by a dialog nobody is
    /// there to answer. Reached only when the ACL is broken, since `read`
    /// checks before it shells out.
    private static let securityToolTimeout: TimeInterval = 5

    /// Whether this item is one Claude Code has to read for itself.
    ///
    /// Only the Claude credential gets the widened ACL. Headroom's own secrets
    /// -- the Devin API key -- have no second reader, so widening them would
    /// give away access that nothing needs.
    ///
    /// `shared` is the override, and exists for one caller: the self test, which
    /// has to exercise this against a service name of its own. It cannot use the
    /// real one. The repair path deletes before it re-adds, and a `SecItemDelete`
    /// that failed to honour `kSecMatchSearchList` would take the live token with
    /// it -- a scratch keychain is not enough isolation to risk that against the
    /// real service string.
    private static func needsClaudeCodeAccess(service: String, shared: Bool?) -> Bool {
        shared ?? (service == ClaudePaths.keychainService)
    }

    // MARK: Silent attribute reads

    /// Whether the item exists, without reading it.
    ///
    /// Asking only for attributes deliberately avoids `kSecReturnData`: returning
    /// the secret is what triggers the "Headroom wants to use your confidential
    /// information" prompt. Existence can be checked silently, so nothing
    /// surprises the user until they actually ask for a swap.
    static func exists(
        service: String = ClaudePaths.keychainService,
        account: String = defaultAccount
    ) -> Bool {
        var q = query(service: service, account: account)
        q[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess
    }

    /// When the item was last written -- Claude Code refreshes the token in
    /// place, so this doubles as "when did this account last talk to the server".
    static func modifiedAt(
        service: String = ClaudePaths.keychainService,
        account: String = defaultAccount
    ) -> Date? {
        var q = query(service: service, account: account)
        q[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any]
        else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }

    // MARK: Read

    /// Reads the secret.
    ///
    /// Routed through `/usr/bin/security` whenever the ACL admits it, which is
    /// the state this file works to keep the item in. That path cannot raise a
    /// dialog -- the caller macOS authorises is `security`, which is on the
    /// list by construction -- so the usual reason a read blocks disappears.
    ///
    /// The direct `SecItemCopyMatching` fallback is for the two cases the tool
    /// cannot serve: an item whose ACL predates this fix and does not name
    /// `security` yet, and Headroom's own creator-only items. Those are exactly
    /// the cases where a prompt is possible, so `allowInteraction` still
    /// governs, and background callers still get a clean refusal instead of a
    /// modal over whatever the user is doing.
    ///
    /// The ACL is not the only gate, though: a *locked* keychain makes
    /// `security` raise the unlock dialog whatever the ACL says, and that
    /// dialog belongs to SecurityAgent, so killing the child on timeout leaves
    /// it on screen. Background callers therefore skip the tool whenever the
    /// keychain is locked and take the framework path, which refuses cleanly.
    static func read(
        service: String = ClaudePaths.keychainService,
        account: String = defaultAccount,
        allowInteraction: Bool = true
    ) throws -> Data {
        if allowInteraction || defaultKeychainIsUnlocked(),
           let data = readViaTrustedSecurityTool(service: service, account: account) {
            return data
        }

        var q = query(service: service, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowInteraction {
            // Background work must never summon a password dialog over whatever
            // the user is doing. If access is not already available, fail and
            // let the automatic action defer until a manual switch authorises it.
            let context = LAContext()
            context.interactionNotAllowed = true
            q[kSecUseAuthenticationContext as String] = context
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw Failure.os(status) }
            return data
        case errSecItemNotFound:
            throw Failure.notFound
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            throw Failure.denied
        default:
            throw Failure.os(status)
        }
    }

    /// The tool read, gated on the ACL actually admitting the tool.
    ///
    /// Checking first is what keeps `read` prompt-free: shelling out to a
    /// `security` the item does not trust is precisely how a dialog appears.
    /// `nil` means "not available this way", never "no credential" -- the
    /// caller falls through to the framework path.
    ///
    /// Grouped into one function so that reading crosses into the deprecated
    /// `SecKeychain*` family exactly once, the same way `write` does. There is
    /// no modern replacement for inspecting an ACL, so the warning cannot be
    /// removed, only confined.
    @available(macOS, deprecated: 10.10)
    private static func readViaTrustedSecurityTool(service: String, account: String) -> Data? {
        guard securityToolIsTrusted(service: service, account: account) == true else { return nil }
        return readViaSecurityTool(service: service, account: account, in: nil)
    }

    /// Whether the default (login) keychain is unlocked right now.
    ///
    /// A status read, never a prompt. Treats an error as "locked", because the
    /// only caller uses the answer to decide whether a prompt is impossible,
    /// and "unknown" is not the same as "impossible". Asks about the default
    /// keychain only, which is where Claude Code's item lives; an item in some
    /// other keychain would merely be read the conservative way.
    @available(macOS, deprecated: 10.10)
    static func defaultKeychainIsUnlocked() -> Bool {
        var status = SecKeychainStatus()
        guard SecKeychainGetStatus(nil, &status) == errSecSuccess else { return false }
        return status & SecKeychainStatus(kSecUnlockStateStatus) != 0
    }

    /// The same command Claude Code runs, for the same reason.
    ///
    /// `nil` on any failure, including the timeout. A timeout means macOS put a
    /// dialog up, which only happens if the ACL check above was wrong about
    /// this item -- so the caller falls through to the framework path rather
    /// than treating it as "no credential".
    private static func readViaSecurityTool(
        service: String, account: String, in keychainPath: String?
    ) -> Data? {
        var arguments = ["find-generic-password", "-a", account, "-s", service, "-w"]
        if let keychainPath { arguments.append(keychainPath) }

        guard let output = runSecurityTool(arguments, timeout: securityToolTimeout),
              output.status == 0
        else { return nil }

        // `-w` prints the password followed by one newline. Trimming exactly
        // that, rather than all whitespace, keeps the payload byte-exact.
        var text = output.stdout
        if text.hasSuffix("\n") { text.removeLast() }
        return text.isEmpty ? nil : Data(text.utf8)
    }

    /// Runs `/usr/bin/security`, bounded, never inheriting a terminal.
    ///
    /// The timeout is the whole point: a blocked read is the failure mode this
    /// file exists to prevent, and an unbounded `waitUntilExit` would convert it
    /// from a dialog into a hung menu bar.
    @discardableResult
    private static func runSecurityTool(
        _ arguments: [String], stdin: String? = nil, timeout: TimeInterval
    ) -> (status: Int32, stdout: String, stderr: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudeCodeReaderPath)
        process.arguments = arguments

        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input

        do { try process.run() } catch { return nil }

        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? input.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            usleep(200_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return nil
        }

        // Read after exit rather than draining concurrently. Safe only because
        // the payload is small: a credential blob is well under a kilobyte and
        // the pipe buffer is 64K, so the child cannot block on a full pipe. A
        // command that could emit more than that would need the concurrent
        // drain back.
        return (process.terminationStatus,
                String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    // MARK: Write

    /// Writes the secret, creating the item if Claude Code has never run.
    ///
    /// Kept free of the deprecation attribute that `writeTargeting` carries, so
    /// that the ordinary call sites are not made to warn about a legacy API they
    /// never asked for. The one crossing point is the call below.
    static func write(
        _ data: Data,
        service: String = ClaudePaths.keychainService,
        account: String = defaultAccount,
        allowInteraction: Bool = true
    ) throws {
        try writeTargeting(data, service: service, account: account,
                           allowInteraction: allowInteraction, in: nil)
    }

    /// `write`, aimed at a specific keychain.
    ///
    /// `keychain` names which one to act on. Production always passes nil,
    /// meaning the default; the self test passes a scratch keychain so it can
    /// exercise this for real without going anywhere near the token the user is
    /// signed in with. It exists because the alternative -- pointing the process
    /// search list at a scratch keychain -- writes through to the user's saved
    /// preferences, so a test that dies mid-run leaves the login keychain out of
    /// the search list. That failure is not hypothetical; it happened while this
    /// was being written.
    ///
    /// `allowInteraction` is accepted and deliberately unused on the write path.
    /// Writing is not gated by the decrypt ACL -- `SecItemUpdate` succeeds on an
    /// item this binary is not allowed to *read* -- and neither is deleting, so
    /// every branch here is prompt-free by construction. The parameter stays
    /// because callers pass it through to reads in the same operation and
    /// silently dropping it from one of the two would invite the mismatch back.
    @available(macOS, deprecated: 10.10)
    static func writeTargeting(
        _ data: Data,
        service: String = ClaudePaths.keychainService,
        account: String = defaultAccount,
        allowInteraction: Bool = true,
        sharedWithClaudeCode: Bool? = nil,
        in keychain: SecKeychain? = nil
    ) throws {
        _ = allowInteraction

        var search = query(service: service, account: account)
        if let keychain { search[kSecMatchSearchList as String] = [keychain] as CFArray }

        let status = SecItemUpdate(
            search as CFDictionary, [kSecValueData as String: data] as CFDictionary)

        if status == errSecSuccess {
            // The item existed, so its ACL is whatever created it left behind:
            // Headroom-only after an old swap, `security`-only after a fresh
            // `claude login`. Neither admits both readers. Correct it now, while
            // the data is in hand -- an ACL cannot be edited in place without an
            // authorisation this process may not hold, but deleting needs no
            // authorisation at all, so replacing the item does the job with no
            // dialog and nothing to lose.
            if needsClaudeCodeAccess(service: service, shared: sharedWithClaudeCode),
               securityToolIsTrusted(service: service, account: account, in: keychain) == false {
                try replaceWithTrustedItem(data, service: service, account: account,
                                           shared: sharedWithClaudeCode, in: keychain)
            }
            return
        }

        guard status == errSecItemNotFound else {
            if status == errSecAuthFailed || status == errSecUserCanceled {
                throw Failure.denied
            }
            throw Failure.os(status)
        }

        try addItem(data, service: service, account: account,
                    shared: sharedWithClaudeCode, in: keychain)
    }

    /// Creates the item, with the ACL that keeps both readers working.
    ///
    /// Accessibility is pinned explicitly: the default is
    /// `kSecAttrAccessibleWhenUnlocked` with this-device-only semantics left to
    /// chance, and Claude Code needs to read this item too.
    @available(macOS, deprecated: 10.10)
    private static func addItem(
        _ data: Data, service: String, account: String,
        shared: Bool?, in keychain: SecKeychain?
    ) throws {
        var insert = query(service: service, account: account)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if needsClaudeCodeAccess(service: service, shared: shared) {
            insert[kSecAttrAccess as String] = try securityToolACL(service: service)
        }
        if let keychain { insert[kSecUseKeychain as String] = keychain }

        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.os(status) }
    }

    /// Deletes and re-creates the item so it carries the right ACL.
    ///
    /// There is a window here in which the item does not exist, and a Claude
    /// Code read landing inside it sees "signed out" rather than a stale token.
    /// That is the safe direction to fail and the window is one `SecItemDelete`
    /// wide; the alternative, `SecKeychainItemSetAccess`, needs an authorisation
    /// this process often does not hold and *blocks on a dialog* when it does
    /// not, which is the failure this whole file is here to remove.
    @available(macOS, deprecated: 10.10)
    private static func replaceWithTrustedItem(
        _ data: Data, service: String, account: String,
        shared: Bool?, in keychain: SecKeychain?
    ) throws {
        var q = query(service: service, account: account)
        if let keychain { q[kSecMatchSearchList as String] = [keychain] as CFArray }

        let status = SecItemDelete(q as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.os(status)
        }
        try addItem(data, service: service, account: account,
                    shared: shared, in: keychain)
    }

    /// An ACL naming the one binary that has to be able to read this item.
    ///
    /// Headroom is deliberately absent. It does not need to be here -- it reads
    /// through the same tool -- and putting it here is what made the ACL rot:
    /// the entry would be matched against an ad-hoc code hash that changes on
    /// every rebuild.
    @available(macOS, deprecated: 10.10)
    private static func securityToolACL(service: String) throws -> SecAccess {
        var reader: SecTrustedApplication?
        let created = SecTrustedApplicationCreateFromPath(claudeCodeReaderPath, &reader)
        guard created == errSecSuccess, let reader else { throw Failure.os(created) }

        var access: SecAccess?
        let status = SecAccessCreate(service as CFString, [reader] as CFArray, &access)
        guard status == errSecSuccess, let access else { throw Failure.os(status) }
        return access
    }

    // MARK: Health

    /// Whether Claude Code can currently read its own token without stopping
    /// the user for a password.
    ///
    /// Safe to call on a timer: it inspects authorisation metadata only, never
    /// `kSecReturnData`, so it cannot itself raise the dialog it is looking for.
    ///
    /// Deliberately asks about the decrypt trusted-application list and nothing
    /// else. An earlier version also required the item's partition list to
    /// contain `apple-tool:`, on the theory that macOS ANDs the two. It does
    /// not, for this item: an item whose ACL names `/usr/bin/security` is
    /// readable by it with any partition list, with a partition list that omits
    /// `apple-tool:`, and with no partition ACL at all. Requiring it made this
    /// return false on a *healthy* item, because `security add-generic-password
    /// -U` -- which is how Claude Code writes a refreshed token, several times a
    /// day -- clears the partition list while leaving the trusted-application
    /// list intact. The result was a standing "Claude Code can't read its token"
    /// warning on a working machine, and an ACL rewrite on every swap to fix
    /// nothing. `SelfTest.keychainPartitionListIsNotAGate` pins the behaviour so
    /// that a macOS release which starts enforcing partitions fails the suite
    /// instead of surprising a user.
    ///
    /// `nil` means the item does not exist yet, which is not a fault: Claude
    /// Code has simply never signed in on this machine.
    @available(macOS, deprecated: 10.10)
    static func claudeCodeCanReadSilently(
        service: String = ClaudePaths.keychainService,
        account: String = defaultAccount,
        in keychain: SecKeychain? = nil
    ) -> Bool? {
        securityToolIsTrusted(service: service, account: account, in: keychain)
    }

    /// `nil` when there is no such item.
    @available(macOS, deprecated: 10.10)
    private static func securityToolIsTrusted(
        service: String, account: String, in keychain: SecKeychain? = nil
    ) -> Bool? {
        guard let item = itemReference(service: service, account: account, in: keychain)
        else { return nil }
        return trustedApplicationPaths(of: item, authorization: kSecACLAuthorizationDecrypt)
            .contains(claudeCodeReaderPath)
    }

    /// Repairs an item whose ACL locks out the tool Claude Code reads through.
    ///
    /// Only reachable for an item Headroom did not write since the fix landed --
    /// every write repairs the ACL as a side effect, and that path needs no
    /// authorisation. What is left for this to handle is the standing case: an
    /// item created by an old build, on a machine where no swap has happened
    /// since.
    ///
    /// The one read here is the only place in Headroom that can still raise a
    /// password dialog, and it does so at most once in the life of the item:
    /// the token cannot be re-created without reading it first, and after this
    /// runs the ACL admits `security`, so nothing needs to ask again. Refusing
    /// to guess is deliberate -- writing the vault's copy instead would replay a
    /// refresh token the server may already have rotated, which does not log the
    /// account out, it revokes it.
    ///
    /// Returns whether the item ended up readable, so the caller can report an
    /// outcome rather than claiming success it did not verify.
    @available(macOS, deprecated: 10.10)
    @discardableResult
    static func repairClaudeCodeAccess(
        service: String = ClaudePaths.keychainService,
        account: String = defaultAccount
    ) -> Bool {
        if securityToolIsTrusted(service: service, account: account) == true { return true }
        guard let data = try? read(service: service, account: account, allowInteraction: true)
        else { return false }
        guard (try? replaceWithTrustedItem(data, service: service, account: account,
                                           shared: nil, in: nil)) != nil
        else { return false }
        return securityToolIsTrusted(service: service, account: account) == true
    }

    // MARK: ACL inspection

    @available(macOS, deprecated: 10.10)
    private static func itemReference(
        service: String, account: String, in keychain: SecKeychain?
    ) -> SecKeychainItem? {
        var q = query(service: service, account: account)
        q[kSecReturnRef as String] = true
        if let keychain { q[kSecMatchSearchList as String] = [keychain] as CFArray }

        var ref: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess,
              let ref,
              CFGetTypeID(ref) == SecKeychainItemGetTypeID()
        else { return nil }
        // swiftlint:disable:next force_cast
        return (ref as! SecKeychainItem)
    }

    /// The trusted-application paths on the ACL entry carrying `authorization`.
    ///
    /// Only the decrypt authorisation matters to any caller of this. The
    /// encrypt ACL is open to every application by design -- writing a secret
    /// nobody can read back is harmless -- so counting it would report every
    /// item as already fine.
    @available(macOS, deprecated: 10.10)
    static func trustedApplicationPaths(
        of item: SecKeychainItem, authorization: CFString
    ) -> Set<String> {
        var access: SecAccess?
        guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access
        else { return [] }

        var aclsRef: CFArray?
        guard SecAccessCopyACLList(access, &aclsRef) == errSecSuccess,
              let acls = aclsRef as? [SecACL]
        else { return [] }

        var paths: Set<String> = []
        for acl in acls {
            guard let authorizations = SecACLCopyAuthorizations(acl) as? [String],
                  authorizations.contains(authorization as String)
            else { continue }

            var apps: CFArray?
            var description: CFString?
            var selector = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &apps, &description, &selector) == errSecSuccess,
                  let apps = apps as? [SecTrustedApplication]
            else { continue }

            for app in apps {
                var data: CFData?
                guard SecTrustedApplicationCopyData(app, &data) == errSecSuccess,
                      let data = data as Data?
                else { continue }
                paths.insert(String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0")))
            }
        }
        return paths
    }

    // MARK: Test support

    /// Runs the real `security find-generic-password -w` against a scratch
    /// keychain, out of process, exactly as Claude Code would.
    ///
    /// This is the only honest way to answer "can Claude Code read this": every
    /// other check in this file inspects what Headroom itself wrote, and an
    /// assertion about your own output cannot catch a wrong theory about macOS.
    /// `nil` means the tool was blocked -- either denied outright or left
    /// waiting on a dialog until the timeout -- which is the failure the whole
    /// file is built to prevent.
    static func securityToolCanRead(
        service: String, account: String = defaultAccount, keychainPath: String
    ) -> Data? {
        readViaSecurityTool(service: service, account: account, in: keychainPath)
    }
}
