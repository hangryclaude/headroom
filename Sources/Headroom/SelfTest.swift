import Foundation

/// `Headroom --selftest` — fixture tests for the pure logic.
///
/// Deliberately in the binary rather than a SwiftPM test target: the executable
/// would have to be split into a library to be importable by tests, and the
/// things most worth pinning here are pure functions with no dependencies. What
/// matters is that they run and that a failure exits non-zero.
///
/// The cases chosen are the ones where being wrong is expensive: pacing maths
/// that could tell the user he has room when he does not, the policy that decides
/// when to move accounts, and the error classification that decides whether he
/// is told to re-login (which would burn a working account).
enum SelfTest {
    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var checks = 0

    static func run() -> Int32 {
        forecaster()
        policy()
        refreshClassification()
        credentials()
        quotaRollover()
        configSurgery()
        lock()
        identity()
        oauthProfile()
        backfill()
        activeAccountResolution()
        swapEngine()
        planValue()
        rolledOverReadings()
        pricing()
        devin()
        keychainAccessControl()

        print("")
        print(failures == 0
              ? "\(checks) checks passed"
              : "\(failures) of \(checks) checks FAILED")
        return failures == 0 ? 0 : 1
    }

    // MARK: Cases

    private static func forecaster() {
        section("Forecaster")

        let now = Date()
        // A window that resets in half a week, i.e. half of it is elapsed.
        let halfway = now.addingTimeInterval(Forecaster.weekLength / 2)

        let onPace = Forecaster.pace(weeklyPercent: 50, resetsAt: halfway, now: now)
        expect(abs(onPace.ratio - 1.0) < 0.01, "50% spent at the halfway mark is on pace")
        expect(!onPace.willExhaust, "on pace does not run out")
        expect(Forecaster.verdict(onPace, now: now) == "on pace", "verdict reads 'on pace'")

        let hot = Forecaster.pace(weeklyPercent: 90, resetsAt: halfway, now: now)
        expect(abs(hot.ratio - 1.8) < 0.01, "90% at halfway is 1.8x pace")
        expect(hot.isOverPace, "90% at halfway is over pace")
        expect(hot.willExhaust, "1.8x pace runs out before the reset")
        if let exhaustsAt = hot.exhaustsAt {
            expect(exhaustsAt > now, "exhaustion is in the future")
            expect(exhaustsAt < hot.resetsAt, "exhaustion lands before the refill")
        } else {
            expect(false, "1.8x pace should project an exhaustion time")
        }

        let cold = Forecaster.pace(weeklyPercent: 10, resetsAt: halfway, now: now)
        expect(cold.isUnderPace, "10% at halfway is under pace")
        expect(!cold.willExhaust, "under pace does not run out")
        expect(Forecaster.verdict(cold, now: now).contains("expires"),
               "under pace warns that unused capacity expires")

        // The first minutes of a window: elapsed is near zero, and a naive
        // spent/elapsed would report a ratio in the thousands.
        let fresh = Forecaster.pace(
            weeklyPercent: 1,
            resetsAt: now.addingTimeInterval(Forecaster.weekLength - 60),
            now: now)
        expect(fresh.ratio < 10, "a barely-started window does not produce an absurd ratio")

        let empty = Forecaster.pace(
            weeklyPercent: 0, resetsAt: halfway, now: now)
        expect(!empty.willExhaust, "zero spend never projects exhaustion")
        expect(Forecaster.verdict(empty, now: now).contains("nothing spent"),
               "zero spend says so plainly")

        // The 5-hour wall: 80% burned with 80% of the window left to run.
        let resets = now.addingTimeInterval(4 * 3600)
        let wall = Forecaster.sessionWall(percent: 80, resetsAt: resets, now: now)
        expect(wall != nil, "80% burned in the first hour projects a wall")
        if let wall { expect(wall < resets, "the wall lands before the reset") }

        let safe = Forecaster.sessionWall(
            percent: 5, resetsAt: now.addingTimeInterval(600), now: now)
        expect(safe == nil, "5% with ten minutes left never hits the wall")
    }

    private static func policy() {
        section("Policy")

        func account(_ name: String, p5: Int, p7: Int, ok: Bool = true) -> AccountReading {
            AccountReading(name: name, label: name, p5: p5, p7: p7,
                           ok: ok, problem: ok ? nil : "no-creds", resets5h: nil)
        }

        let empty = Policy.decide(current: nil, accounts: [])
        expect(empty.verdict == .noAccounts, "no accounts gives NO-ACCOUNTS")

        // The 5-hour throttle is hit and somewhere cold exists.
        let hot = account("a", p5: 85, p7: 40)
        let cool = account("b", p5: 10, p7: 30)
        let swap = Policy.decide(current: hot, accounts: [hot, cool])
        expect(swap.verdict == .swap, "5h at 85% forces a swap")
        expect(swap.target == "b", "it swaps to the cold account")

        // The week outranks the throttle: comfortable 5h, but the week is spent.
        let weekGone = account("a", p5: 10, p7: 95)
        let fresh = account("b", p5: 20, p7: 20)
        let weekly = Policy.decide(current: weekGone, accounts: [weekGone, fresh])
        expect(weekly.verdict == .swap, "7d at 95% forces a swap even with 5h room")
        expect(weekly.target == "b", "weekly exhaustion moves to the account with budget")

        // Warm but not urgent, with somewhere genuinely cold to go.
        let warm = account("a", p5: 65, p7: 40)
        let cold = account("b", p5: 5, p7: 20)
        let soon = Policy.decide(current: warm, accounts: [warm, cold])
        expect(soon.verdict == .rotateSoon, "5h at 65% with a cold peer says rotate soon")
        expect(soon.why.contains("not mid-task"), "rotate-soon explains it can wait")

        // Even burn matters because unused weekly capacity expires.
        let heavy = account("a", p5: 10, p7: 60)
        let light = account("b", p5: 10, p7: 20)
        let rebalance = Policy.decide(current: heavy, accounts: [heavy, light])
        expect(rebalance.verdict == .rebalance, "a 40-point weekly spread rebalances")

        // Nowhere to go.
        let hotA = account("a", p5: 95, p7: 50)
        let hotB = account("b", p5: 92, p7: 50)
        let allHot = Policy.decide(current: hotA, accounts: [hotA, hotB])
        expect(allHot.verdict == .allHot, "no eligible account gives ALL-HOT")
        expect(allHot.target == nil, "ALL-HOT has no target")

        // Healthy and balanced.
        let good = account("a", p5: 20, p7: 30)
        let peer = account("b", p5: 25, p7: 28)
        let stay = Policy.decide(current: good, accounts: [good, peer])
        expect(stay.verdict == .stay, "a healthy balanced pair stays put")
        expect(stay.verdict.accentPercent == nil, "a healthy verdict carries no colour")

        // A broken current account moves off itself.
        let broken = account("a", p5: 0, p7: 0, ok: false)
        let alive = account("b", p5: 10, p7: 10)
        let recover = Policy.decide(current: broken, accounts: [broken, alive])
        expect(recover.verdict == .swap, "a broken account swaps away")
        expect(recover.why.contains("needs login"),
               "raw problem codes are humanised before display")

        // Ranking: lowest 0.75*p7 + 0.25*p5 wins, so the week dominates.
        let lowWeek = account("low7", p5: 70, p7: 10)
        let lowHour = account("low5", p5: 5, p7: 50)
        let ranked = Policy.eligible([lowHour, lowWeek])
        expect(ranked.first?.name == "low7", "the weekly term outweighs the hourly one")
    }

    private static func refreshClassification() {
        section("Token refresh")

        // OAuth shape. This is the only one that means the account is dead.
        let dead = TokenRefresher.classify(
            ["error": "invalid_grant", "error_description": "refresh token expired"])
        expect(dead == .needsLogin("refresh token expired"), "invalid_grant means re-login")

        // Anthropic shape. Transient — reporting this as needs-login would send
        // the user to burn a working account.
        let limited = TokenRefresher.classify(
            ["error": ["type": "rate_limit_error", "message": "slow down"]])
        expect(limited == .rateLimited("slow down"), "rate_limit_error is transient")
        expect(!limited.isTerminal, "a rate limit is never terminal")

        let overloaded = TokenRefresher.classify(["error": ["type": "overloaded_error"]])
        if case .rateLimited = overloaded {} else {
            expect(false, "overloaded_error is treated as transient")
        }
        checks += 1

        let unknown = TokenRefresher.classify(["error": ["type": "teapot"]])
        if case .failed = unknown {} else { expect(false, "an unknown error is not a re-login") }
        checks += 1

        // Merging must never blank a refresh token the server did not resend.
        let original = Credentials(raw: Data(#"{"claudeAiOauth":{"accessToken":"old","refreshToken":"keep","expiresAt":1}}"#.utf8))
        let merged = TokenRefresher.merge(["access_token": "new", "expires_in": 3600], into: original)
        expect(merged?.accessToken == "new", "the access token is replaced")
        expect(merged?.refreshToken == "keep",
               "a refresh token absent from the response is preserved, not blanked")
        if let expiresAt = merged?.expiresAt {
            expect(expiresAt > Date(), "expiry moves into the future")
        } else {
            expect(false, "expiry is rewritten from expires_in")
        }

        let rotated = TokenRefresher.merge(
            ["access_token": "new", "refresh_token": "rotated"], into: original)
        expect(rotated?.refreshToken == "rotated", "a rotated refresh token is stored")

        // Regression: an earlier merge only overwrote keys that already existed,
        // so a blob with no refreshToken key silently dropped the rotated token
        // while the server had already consumed the old one. Dead account.
        let noRefreshKey = Credentials(raw: Data(#"{"claudeAiOauth":{"accessToken":"old","scopes":[]}}"#.utf8))
        let added = TokenRefresher.merge(
            ["access_token": "new", "refresh_token": "fresh"], into: noRefreshKey)
        expect(added?.refreshToken == "fresh",
               "a rotated refresh token is ADDED when the blob had no such key")
        expect(added?.accessToken == "new", "the access token is written alongside it")

        // Snake-case blobs keep their own convention rather than growing a
        // second, camelCase copy of the same field.
        let snake = Credentials(raw: Data(#"{"access_token":"old","refresh_token":"old_r"}"#.utf8))
        let snakeMerged = TokenRefresher.merge(
            ["access_token": "new", "refresh_token": "new_r"], into: snake)
        expect(snakeMerged?.accessToken == "new", "snake_case blobs merge correctly")
        if let raw = snakeMerged?.raw,
           let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            expect(object["accessToken"] == nil,
                   "merging does not add a duplicate camelCase key")
        }

        // Nothing recognisable to update must fail loudly rather than persist a
        // blob still carrying the consumed token.
        let unrecognisable = Credentials(raw: Data(#"{"something":"else"}"#.utf8))
        expect(TokenRefresher.merge(["access_token": "new"], into: unrecognisable) == nil,
               "an unrecognisable blob returns nil instead of a silent no-op")

        // The raw-response triage that decides which file gets overwritten.
        expect(TokenRefresher.containsToken(Data(#"{"access_token":"x"}"#.utf8)),
               "a rotated response is detected before parsing")
        expect(!TokenRefresher.containsToken(Data(#"{"error":"invalid_grant"}"#.utf8)),
               "an error response is not mistaken for a token")
    }

    private static func lock() {
        section("Refresh mutex")

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "headroom-lock-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let lock = directory.appending(path: ".refresh.lock")

        guard let first = TokenRefresher.acquireLock(lock) else {
            expect(false, "the first acquire succeeds")
            return
        }
        expect(true, "the first acquire succeeds")
        expect(TokenRefresher.acquireLock(lock) == nil, "a second acquire is refused")

        // Releasing with somebody else's token must not remove the lock -- that
        // is what let two redemptions run concurrently.
        TokenRefresher.releaseLock(lock, ownership: "not-the-owner")
        expect(FileManager.default.fileExists(atPath: lock.path),
               "releasing with the wrong token leaves the lock alone")

        TokenRefresher.releaseLock(lock, ownership: first)
        expect(!FileManager.default.fileExists(atPath: lock.path),
               "releasing with the right token frees it")

        expect(TokenRefresher.acquireLock(lock) != nil, "the lock can be taken again")
    }

    private static func credentials() {
        section("Credentials")

        let nested = Credentials(raw: Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r"}}"#.utf8))
        expect(nested.accessToken == "a", "nested claudeAiOauth shape")

        let flat = Credentials(raw: Data(#"{"access_token":"a2","refresh_token":"r2"}"#.utf8))
        expect(flat.accessToken == "a2", "flat snake_case shape")

        let camel = Credentials(raw: Data(#"{"accessToken":"a3"}"#.utf8))
        expect(camel.accessToken == "a3", "flat camelCase shape")

        // The fingerprint identifies the account, so it must ignore expiry --
        // otherwise every routine refresh looks like an account change.
        let early = Credentials(raw: Data(#"{"accessToken":"a","refreshToken":"r","expiresAt":1}"#.utf8))
        let later = Credentials(raw: Data(#"{"accessToken":"a","refreshToken":"r","expiresAt":999}"#.utf8))
        expect(early.fingerprint == later.fingerprint,
               "expiry does not move the fingerprint")

        let other = Credentials(raw: Data(#"{"accessToken":"b","refreshToken":"r"}"#.utf8))
        expect(early.fingerprint != other.fingerprint, "a different token is a different account")
    }

    private static func quotaRollover() {
        section("Quota")

        let now = Date()
        // A window whose reset has already passed: the percentage on disk
        // describes a window that no longer exists.
        let past = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))
        let stale = QuotaReader.parseLimit(
            ["kind": "session", "percent": 79, "resets_at": past], now: now)
        expect(stale?.reading == .rolledOver,
               "an elapsed resets_at rolls over rather than trusting the stale percent")

        let future = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))
        let live = QuotaReader.parseLimit(
            ["kind": "session", "percent": 42, "resets_at": future], now: now)
        expect(live?.reading == .live(42), "a live window keeps its percentage")

        let scoped = QuotaReader.parseLimit(
            ["kind": "weekly_scoped", "percent": 0,
             "scope": ["model": ["display_name": "Fable"]]], now: now)
        expect(scoped?.kind == .weeklyScoped("Fable"), "scoped caps carry the model name")

        let unknown = QuotaReader.parseLimit(["kind": "tangelo", "percent": 5], now: now)
        expect(unknown == nil, "unrecognised limit kinds are dropped, not guessed at")

        // Six fractional digits and a +00:00 offset, as the server sends it.
        expect(QuotaReader.parseTimestamp("2026-08-06T22:40:00.473963+00:00") != nil,
               "fractional-second timestamps parse")
        expect(QuotaReader.parseTimestamp("2026-08-06T22:40:00Z") != nil,
               "plain timestamps parse")
    }

    /// The `~/.claude.json` edit, run against a real copy of the real file.
    ///
    /// This is the operation that can silently destroy work: caam copies the
    /// whole file on a swap, which drags `projects` and `mcpServers` along with
    /// the identity. Testing it on a throwaway copy of the actual config -- not a
    /// hand-written fixture -- is the only way to know it survives the shape the
    /// file really has, including keys added by a future Claude Code release.
    private static func configSurgery() {
        section("Config surgery")

        let source = ClaudePaths.configJSON
        guard let original = FileManager.default.contents(atPath: source.path),
              let before = try? JSONSerialization.jsonObject(with: original) as? [String: Any]
        else {
            print("  skip  no ~/.claude.json to copy")
            return
        }

        let copy = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "headroom-selftest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: copy) }

        do {
            try original.write(to: copy)
            try AccountVault.repointConfig(at: copy)
        } catch {
            expect(false, "the surgery runs without throwing: \(error)")
            return
        }

        guard let edited = FileManager.default.contents(atPath: copy.path),
              let after = try? JSONSerialization.jsonObject(with: edited) as? [String: Any]
        else {
            expect(false, "the edited file is still valid JSON")
            return
        }

        for key in AccountVault.accountCoupledKeys where before[key] != nil {
            expect(after[key] == nil, "account-coupled key '\(key)' is cleared")
        }

        // Everything else must survive untouched. This is the half caam gets
        // wrong, and the half that costs the user real state.
        let preserved = Set(before.keys).subtracting(AccountVault.accountCoupledKeys)
        let missing = preserved.filter { after[$0] == nil }
        expect(missing.isEmpty,
               "every unrelated key survives (\(preserved.count) checked)"
               + (missing.isEmpty ? "" : " — lost \(missing.sorted().joined(separator: ", "))"))

        // Named explicitly because these are the ones whose loss would hurt most.
        for key in ["projects", "mcpServers", "numStartups", "firstStartTime"]
        where before[key] != nil {
            expect(after[key] != nil, "'\(key)' is preserved")
        }

        // And the original must not have been touched at all.
        let sourceNow = FileManager.default.contents(atPath: source.path)
        expect(sourceNow == original, "the real config is left byte-identical")
    }

    /// Accounts are identified by UUID, not by a hash of the credential.
    ///
    /// This is a regression guard for the worst bug in the project: identifying
    /// the active account by credential fingerprint meant a routine token
    /// rotation made it unrecognisable, so the live account was treated as
    /// inactive and its already-consumed refresh token got redeemed.
    private static func identity() {
        section("Account identity")

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "headroom-identity-\(UUID().uuidString)")
        let config = root.appending(path: "claude.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let uuid = "74e540af-77c4-4bf1-abde-9ac3f28d93cd"
        let json = """
        {"oauthAccount":{"emailAddress":"a@b.com","accountUuid":"\(uuid)",
         "organizationRateLimitTier":"default_claude_max_20x"}}
        """
        try? Data(json.utf8).write(to: config)

        guard let read = IdentityReader(configURL: config).read() else {
            expect(false, "identity parses from a config file")
            return
        }
        expect(read.accountUUID == uuid, "the account UUID is read")
        expect(read.planLabel == "Max 20x", "the plan tier is humanised")
        expect(read.handle == "a", "the handle is the local part of the email")

        // The fingerprint moves when the token rotates; the UUID does not. That
        // difference is the whole point.
        let before = Credentials(raw: Data(#"{"accessToken":"t1","refreshToken":"r1"}"#.utf8))
        let after = Credentials(raw: Data(#"{"accessToken":"t2","refreshToken":"r2"}"#.utf8))
        expect(before.fingerprint != after.fingerprint,
               "a rotated token changes the fingerprint (which is why it cannot identify an account)")
    }

    /// The plan tier on a newly signed-in account.
    ///
    /// Regression guard for a bug that shipped: `blob` read the tier out of the
    /// token response, and the token response has never carried it. Every account
    /// added through `OAuthFlow` was therefore stored with no plan, while the one
    /// account captured from the Keychain had one — because Claude Code's own
    /// bootstrap had already written the tier into `~/.claude.json`.
    ///
    /// The fixtures below are the real response shapes, keys and all, taken from
    /// a live exchange and a live profile call rather than written from the docs.
    private static func oauthProfile() {
        section("OAuth profile")

        // Exactly what the token endpoint returns. Note what is absent: no
        // organization_type, no rate_limit_tier. That absence is the bug.
        let tokenResponse = """
        {"token_type":"Bearer","access_token":"at","expires_in":28800,
         "refresh_token":"rt","scope":"user:profile user:inference",
         "token_uuid":"tu","refresh_token_expires_in":31536000,
         "organization":{"uuid":"org-uuid","name":"High Camp"},
         "account":{"uuid":"acct-uuid","email_address":"a@b.com"}}
        """
        guard let token = try? JSONSerialization.jsonObject(
            with: Data(tokenResponse.utf8)) as? [String: Any] else {
            expect(false, "the token fixture parses"); return
        }

        expect(OAuthFlow.identity(from: token)?.planLabel == "—",
               "the token response alone yields no plan — this is the whole bug")

        let profileResponse = """
        {"account":{"uuid":"acct-uuid","email":"a@b.com","full_name":"angus",
                    "has_claude_max":false},
         "organization":{"uuid":"org-uuid","name":"High Camp",
                         "organization_type":"claude_team",
                         "rate_limit_tier":"default_claude_max_5x",
                         "seat_tier":"team_tier_1"},
         "application":{"name":"Claude Code"}}
        """
        guard let profile = OAuthFlow.identity(fromProfile: Data(profileResponse.utf8)) else {
            expect(false, "the profile response parses into an identity"); return
        }
        expect(profile.email == "a@b.com", "profile carries the email")
        expect(profile.accountUUID == "acct-uuid", "profile carries the account UUID")
        expect(profile.rateLimitTier == "default_claude_max_5x", "profile carries the tier")
        expect(profile.planLabel == "Max 5x", "a team seat on Max 5x reads as 'Max 5x'")

        // A profile that came back without an account is not an identity. Storing
        // a half-populated one would overwrite a good email with nothing.
        expect(OAuthFlow.identity(fromProfile: Data(#"{"organization":{"uuid":"o"}}"#.utf8)) == nil,
               "a profile with no account yields nil rather than a partial identity")

        // The fix: the tier reaches the stored credential, in Claude Code's own
        // shape, so a swapped-in blob is indistinguishable from one it wrote.
        let filled = OAuthFlow.blob(from: token, accessToken: "at", profile: profile)
        guard let oauth = try? JSONSerialization.jsonObject(with: filled.raw) as? [String: Any],
              let claude = oauth["claudeAiOauth"] as? [String: Any] else {
            expect(false, "the credential blob is valid JSON"); return
        }
        expect(claude["rateLimitTier"] as? String == "default_claude_max_5x",
               "the tier is written into the credential")
        expect(claude["subscriptionType"] as? String == "team",
               "organization_type is stored with the claude_ prefix stripped")
        expect(claude["accessToken"] as? String == "at", "the token still lands")

        // The profile call is best-effort: it happens after the tokens are minted,
        // so a failure there must never lose them.
        let bare = OAuthFlow.blob(from: token, accessToken: "at", profile: nil)
        guard let bareOAuth = try? JSONSerialization.jsonObject(with: bare.raw) as? [String: Any],
              let bareClaude = bareOAuth["claudeAiOauth"] as? [String: Any] else {
            expect(false, "the blob is still valid with no profile"); return
        }
        expect(bareClaude["accessToken"] as? String == "at",
               "a failed profile lookup still stores the tokens")
        expect(bareClaude["refreshToken"] as? String == "rt",
               "and still stores the refresh token")

        // The diagnostic that used to be a live token set on disk.
        let record = OAuthFlow.shapeRecord(of: Data(tokenResponse.utf8))
        let text = String(decoding: record, as: UTF8.self)
        expect(text.contains("access_token"), "the shape record keeps the key names")
        expect(!text.contains("\"at\""), "the shape record does not keep the access token")
        expect(!text.contains("\"rt\""), "the shape record does not keep the refresh token")
        expect(text.contains("organization.name"), "nested keys are flattened, not dropped")
    }

    /// Filling in the plan on accounts that were added before the profile call
    /// existed, without a re-login.
    ///
    /// The guard being tested is the same one `capture` and `adopt` enforce:
    /// account identity is the UUID, so backfilling one onto a slot that would
    /// collide with another slot has to refuse rather than write. Two entries
    /// sharing a UUID is the shape that made the live account unrecognisable and
    /// got its consumed refresh token replayed.
    /// Which account the vault believes is installed, in the window where
    /// `~/.claude.json` cannot answer.
    ///
    /// This is the regression test for the worst of the swap bugs. `activate`
    /// finishes by deleting `oauthAccount`, and identity used to be read only
    /// from there, so every swap was followed by a window in which Headroom
    /// believed nothing was active. The forced usage refresh that runs right
    /// after a swap skips the active account -- so with nothing active it
    /// reached for the account just installed, found the vault's copy of its
    /// token expired (the usual reason to switch to a dormant account), and
    /// redeemed its refresh token. The rotated pair was written to the vault
    /// file only, so the Keychain kept a refresh token the server had already
    /// consumed. Anthropic's reuse detection then revoked the family: the
    /// account did not merely need signing in again, it was dead.
    ///
    /// The marker has to beat a *stale* `oauthAccount`, not merely a missing
    /// one, which is the second half of what is asserted here: a long-running
    /// Claude Code process can rewrite that file from memory after a swap and
    /// put the previous account's UUID back.
    private static func activeAccountResolution() {
        section("Active account resolution")

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "headroom-active-\(UUID().uuidString)")
        let config = root.appending(path: "claude.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let vault = AccountVault(root: root, identityURL: config)
        let one = Identity(email: "one@x.com", accountUUID: "uuid-one", organizationUUID: nil,
                           organizationType: nil, rateLimitTier: nil)
        let two = Identity(email: "two@x.com", accountUUID: "uuid-two", organizationUUID: nil,
                           organizationType: nil, rateLimitTier: nil)
        guard (try? vault.adopt(Credentials(raw: Data(#"{"accessToken":"a"}"#.utf8)),
                                identity: one, as: "one")) != nil,
              (try? vault.adopt(Credentials(raw: Data(#"{"accessToken":"b"}"#.utf8)),
                                identity: two, as: "two")) != nil else {
            expect(false, "two accounts adopt into a fresh vault"); return
        }

        func writeConfig(uuid: String?, email: String) {
            var root: [String: Any] = ["projects": ["keep": "me"]]
            if let uuid {
                root["oauthAccount"] = ["accountUuid": uuid, "emailAddress": email]
            }
            let data = try? JSONSerialization.data(withJSONObject: root)
            try? data?.write(to: config, options: .atomic)
        }

        writeConfig(uuid: "uuid-one", email: "one@x.com")
        expect(vault.activeAccount()?.name == "one",
               "with no marker, the account named by oauthAccount is the active one")

        writeConfig(uuid: nil, email: "")
        expect(vault.activeAccount() == nil,
               "with no marker and no oauthAccount, nothing is active — the old behaviour")

        // The swap window: oauthAccount has just been deleted by repointConfig.
        vault.recordActive("two")
        expect(vault.activeAccount()?.name == "two",
               "a marker names the installed account while oauthAccount is missing")

        // And the harder case: Claude Code writes the *previous* account's
        // identity back from a stale in-memory cache after the swap.
        writeConfig(uuid: "uuid-one", email: "one@x.com")
        expect(vault.activeAccount()?.name == "two",
               "a valid marker outranks a resurrected, stale oauthAccount")

        // A marker whose Keychain no longer matches loses to a *conflicting*
        // oauthAccount: something else has written the item since, so Claude
        // Code's own record is the better evidence.
        let stale = #"{"name":"two","keychainModifiedAt":-63000000}"#
        try? Data(stale.utf8).write(to: root.appending(path: "active.json"), options: .atomic)
        expect(vault.activeAccount()?.name == "one",
               "a marker the Keychain has moved on from loses to a conflicting oauthAccount")

        // But with nothing to conflict with, the marker's name still stands. A
        // later write rotates the *token*; it does not change which account is
        // installed. Requiring a matching date here reopened the original bug in
        // a narrower window — a rotation landing before Claude Code writes
        // oauthAccount back left nobody able to name the installed account, and
        // the outgoing re-snapshot was skipped all over again.
        writeConfig(uuid: nil, email: "")
        expect(vault.activeAccount()?.name == "two",
               "a marker still names the installed account after a token rotation, "
               + "when oauthAccount has nothing to say")

        // A marker naming an account that has since been forgotten must not
        // resurrect it as active. oauthAccount is restored first, so the
        // assertion is about the marker being discarded rather than about there
        // being nothing left to fall back to.
        writeConfig(uuid: "uuid-one", email: "one@x.com")
        vault.recordActive("two")
        expect((try? vault.forget("two")) != nil, "the marked account can be forgotten")
        expect(vault.activeAccount()?.name == "one",
               "a marker pointing at a deleted account falls back rather than dangling")
    }

    /// A Keychain that lives in memory, so the swap engine can be run for real.
    ///
    /// `activate` overwrites the only copy of a live OAuth token. It had no test
    /// of any kind, because exercising it meant touching the Keychain the user is
    /// signed in with. That is why every check could pass while the swap path
    /// carried an account-destroying bug.
    private final class FakeCredentialStore: CredentialStore, @unchecked Sendable {
        var data: Data?
        var modified: Date?
        var readError: Error?
        var writeError: Error?
        private(set) var writes = 0

        init(_ data: Data?) {
            self.data = data
            self.modified = data == nil ? nil : Date(timeIntervalSince1970: 1)
        }

        func exists() -> Bool { data != nil }
        func modifiedAt() -> Date? { modified }

        func read(allowInteraction: Bool) throws -> Data {
            if let readError { throw readError }
            guard let data else { throw Keychain.Failure.notFound }
            return data
        }

        func write(_ new: Data, allowInteraction: Bool) throws {
            if let writeError { throw writeError }
            writes += 1
            data = new
            // A distinct instant per write, which is what the marker keys off.
            modified = Date(timeIntervalSince1970: 1 + Double(writes))
        }

        /// Claude Code refreshing the token in place: same account, new bytes.
        func rotateInPlace(_ new: Data) {
            data = new
            modified = Date(timeIntervalSince1970: 500)
        }
    }

    /// The swap engine, run end to end against an in-memory Keychain.
    private static func swapEngine() {
        section("Swap engine")

        struct Fixture {
            let vault: AccountVault
            let store: FakeCredentialStore
            let root: URL
            let config: URL
        }

        func makeFixture() -> Fixture? {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "headroom-swap-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let config = root.appending(path: "claude.json")
            let store = FakeCredentialStore(Data(#"{"accessToken":"live-a","refreshToken":"ra"}"#.utf8))
            // An empty sessions directory, so the guard sees no live Claude Code
            // and the swap is not refused as busy. Without this the suite passes
            // or fails depending on whether the person running it happens to
            // have a session mid-request, which is not a test.
            let sessions = root.appending(path: "sessions")
            try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let vault = AccountVault(root: root,
                                     guardian: SessionGuard(sessionsDir: sessions),
                                     identityURL: config, store: store)

            for (name, uuid, token) in [("a", "uuid-a", "a"), ("b", "uuid-b", "b"), ("c", "uuid-c", "c")] {
                let identity = Identity(email: "\(name)@x.com", accountUUID: uuid,
                                        organizationUUID: nil, organizationType: nil,
                                        rateLimitTier: nil)
                let raw = Data(#"{"accessToken":"vault-\#(token)","refreshToken":"r\#(token)"}"#.utf8)
                guard (try? vault.adopt(Credentials(raw: raw), identity: identity, as: name)) != nil
                else { return nil }
            }
            let root0: [String: Any] = [
                "projects": ["keep": "me"],
                "oauthAccount": ["accountUuid": "uuid-a", "emailAddress": "a@x.com"],
            ]
            try? JSONSerialization.data(withJSONObject: root0).write(to: config, options: .atomic)
            return Fixture(vault: vault, store: store, root: root, config: config)
        }

        func storedToken(_ f: Fixture, _ name: String) -> String? {
            let url = f.root.appending(path: name).appending(path: "credentials.json")
            guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }

        // 1. The ordinary swap.
        guard let f1 = makeFixture() else { expect(false, "a swap fixture builds"); return }
        defer { try? FileManager.default.removeItem(at: f1.root) }
        guard let installed = try? f1.vault.activate("b") else {
            expect(false, "a swap to a stored account succeeds"); return
        }
        expect(installed.name == "b", "activate reports the account it installed")
        expect(f1.store.data == Data(#"{"accessToken":"vault-b","refreshToken":"rb"}"#.utf8),
               "the Keychain ends up holding the target account's credential")
        expect(f1.vault.activeAccount()?.name == "b",
               "the swapped-to account is active immediately, before Claude Code relaunches")

        // Rule 1: the outgoing account's *live* token, not the vault's older copy.
        expect(storedToken(f1, "a")?.contains("live-a") == true,
               "the outgoing account is re-snapshotted from the live credential")

        // repointConfig ran, so the identity cache is cleared for the newcomer.
        let after = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: f1.config))) as? [String: Any]
        expect(after?["oauthAccount"] == nil, "the swap clears the stale identity cache")
        expect(after?["projects"] != nil, "the swap leaves unrelated config keys alone")

        // 2. Swapping to what is already installed is refused.
        if case .some = try? f1.vault.activate("b") {
            expect(false, "swapping to the active account is refused")
        } else {
            expect(true, "swapping to the active account is refused")
        }

        // 3. The regression: a second swap before Claude Code has relaunched.
        //
        // `oauthAccount` is still absent here, which used to mean the outgoing
        // account matched nothing, so its live credential was never written to
        // its own slot -- only into a dated backup directory.
        f1.store.rotateInPlace(Data(#"{"accessToken":"live-b-rotated","refreshToken":"rb2"}"#.utf8))
        guard (try? f1.vault.activate("c")) != nil else {
            expect(false, "a second swap before Claude Code relaunches succeeds"); return
        }
        expect(storedToken(f1, "b")?.contains("live-b-rotated") == true,
               "the second swap re-snapshots the outgoing account's rotated token into its own slot")
        expect(f1.vault.activeAccount()?.name == "c", "the second swap is reflected immediately")

        // 4. An unreadable outgoing credential refuses the swap without writing.
        guard let f4 = makeFixture() else { expect(false, "a second fixture builds"); return }
        defer { try? FileManager.default.removeItem(at: f4.root) }
        f4.store.readError = Keychain.Failure.denied
        let before4 = f4.store.data
        if case .some = try? f4.vault.activate("b") {
            expect(false, "a swap refuses when the outgoing credential cannot be read")
        } else {
            expect(true, "a swap refuses when the outgoing credential cannot be read")
        }
        expect(f4.store.data == before4,
               "the refused swap leaves the Keychain untouched — never overwrite what you could not copy")

        // 5. A failed install fails in the safe direction: the identity cache is
        //    cleared in front of an unchanged token, which Claude Code
        //    repopulates correctly. The alternative order reports a swap that
        //    actually happened as a failure.
        guard let f5 = makeFixture() else { expect(false, "a third fixture builds"); return }
        defer { try? FileManager.default.removeItem(at: f5.root) }
        f5.store.writeError = Keychain.Failure.denied
        let before5 = f5.store.data
        if case .some = try? f5.vault.activate("b") {
            expect(false, "a swap whose install fails is reported as a failure")
        } else {
            expect(true, "a swap whose install fails is reported as a failure")
        }
        expect(f5.store.data == before5, "the failed install left the previous token in place")

        // 6. Signed in to an account the vault has never seen: its credential is
        //    about to be overwritten, so a copy is parked rather than discarded.
        guard let f6 = makeFixture() else { expect(false, "a fourth fixture builds"); return }
        defer { try? FileManager.default.removeItem(at: f6.root) }
        try? JSONSerialization.data(withJSONObject: ["projects": ["keep": "me"]])
            .write(to: f6.config, options: .atomic)
        try? FileManager.default.removeItem(at: f6.root.appending(path: "active.json"))
        guard (try? f6.vault.activate("b")) != nil else {
            expect(false, "a swap away from an unknown account succeeds"); return
        }
        expect(storedToken(f6, AccountVault.unsavedSlot)?.contains("live-a") == true,
               "an unrecognised outgoing credential is parked rather than discarded")
    }

    private static func backfill() {
        section("Identity backfill")

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "headroom-backfill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = AccountVault(root: root)

        let credentials = Credentials(raw: Data(#"{"accessToken":"a","refreshToken":"r"}"#.utf8))
        let other = Credentials(raw: Data(#"{"accessToken":"b","refreshToken":"s"}"#.utf8))
        guard (try? vault.adopt(credentials, identity: nil, as: "one")) != nil,
              (try? vault.adopt(other, identity: nil, as: "two")) != nil else {
            expect(false, "two accounts adopt into a fresh vault"); return
        }
        expect(vault.accounts().first(where: { $0.name == "one" })?.plan == nil,
               "an account adopted without an identity starts with no plan")

        let identity = Identity(
            email: "a@b.com", accountUUID: "uuid-one", organizationUUID: "org",
            organizationType: "claude_max", rateLimitTier: "default_claude_max_20x")
        expect((try? vault.updateIdentity(identity, for: "one")) == true,
               "backfilling an account with a free UUID succeeds")

        let filled = vault.accounts().first { $0.name == "one" }
        expect(filled?.email == "a@b.com", "the email lands")
        expect(filled?.plan == "Max 20x", "the plan lands, humanised")
        expect(filled?.accountUUID == "uuid-one", "the UUID lands")
        expect(filled?.rateLimitTier == "default_claude_max_20x",
               "the raw tier lands alongside the label, so pricing has a stable key")
        expect(filled?.fingerprint == credentials.fingerprint,
               "backfill does not disturb the credential fingerprint")

        // The same identity against a second slot is the collision case.
        expect((try? vault.updateIdentity(identity, for: "two")) == false,
               "backfilling a UUID another account already holds is refused")
        expect(vault.accounts().first(where: { $0.name == "two" })?.email == nil,
               "the refused account is left untouched rather than half-written")
        expect(vault.accounts().first(where: { $0.name == "one" })?.email == "a@b.com",
               "and the account that legitimately holds the UUID keeps it")

        // Re-running the backfill over an account that already has the identity
        // is the normal case on a second run, and must not trip its own guard.
        expect((try? vault.updateIdentity(identity, for: "one")) == true,
               "re-backfilling the same account with the same UUID is idempotent")
    }

    /// What a week of unused subscription is worth.
    ///
    /// Deliberately denominated in dollars-of-subscription rather than tokens.
    /// Converting an unused percentage into a token count needs a
    /// tokens-per-percent anchor that varies by model mix and cache ratio, so any
    /// figure would be an estimate dressed as a measurement. The subscription
    /// price is exact, and a percentage of it is still exact.
    private static func planValue() {
        section("Unused subscription")

        expect(PlanValue.monthlyPrice(forTier: "default_claude_max_20x") == 200,
               "Max 20x is $200/month")
        expect(PlanValue.monthlyPrice(forTier: "default_claude_max_5x") == 100,
               "Max 5x is $100/month")
        expect(PlanValue.monthlyPrice(forTier: "default_claude_pro") == 20,
               "Pro is $20/month")
        expect(PlanValue.monthlyPrice(forTier: nil) == nil,
               "an unknown tier prices as nil rather than guessing")
        expect(PlanValue.monthlyPrice(forTier: "default_claude_tangelo_9x") == nil,
               "an unrecognised tier prices as nil rather than guessing")

        // 12 monthly payments buy 52 weekly windows, not 48 -- the naive
        // month/4 conversion overstates every weekly figure by ~8%.
        guard let weekly = PlanValue.weeklyPrice(forTier: "default_claude_max_20x") else {
            expect(false, "Max 20x has a weekly price"); return
        }
        expect(abs(weekly - (200 * 12 / 52)) < 0.01,
               "a weekly window costs monthly x 12 / 52, not monthly / 4")

        guard let spent = PlanValue.expired(weeklyPercent: 96, tier: "default_claude_max_20x"),
              let idle = PlanValue.expired(weeklyPercent: 4, tier: "default_claude_max_20x")
        else { expect(false, "expired() prices a known tier"); return }
        expect(abs(spent - weekly * 0.04) < 0.01,
               "96% used leaves 4% of the week's price expiring")
        expect(abs(idle - weekly * 0.96) < 0.01,
               "4% used leaves 96% of it expiring")
        expect(idle > spent, "the barely-touched account wastes more than the hammered one")

        // A window nobody touched wastes the whole thing, and one run to the wall
        // wastes nothing. Both ends have to be exact or the headline is wrong.
        expect(PlanValue.expired(weeklyPercent: 0, tier: "default_claude_max_5x")
               == PlanValue.weeklyPrice(forTier: "default_claude_max_5x"),
               "an untouched week wastes its entire price")
        expect(PlanValue.expired(weeklyPercent: 100, tier: "default_claude_max_5x") == 0,
               "a fully-used week wastes nothing")

        // The server has been seen reporting over 100 on a rolled-over window.
        // Left unclamped that yields negative waste, which would quietly subtract
        // from the fleet total and understate the headline.
        expect(PlanValue.expired(weeklyPercent: 118, tier: "default_claude_max_20x") == 0,
               "a percentage above 100 clamps to zero waste, never negative")
        expect(PlanValue.expired(weeklyPercent: -5, tier: "default_claude_max_20x") == weekly,
               "a negative percentage clamps to a fully wasted week")
        expect(PlanValue.expired(weeklyPercent: 50, tier: "who-knows") == nil,
               "an unknown tier yields no waste figure rather than a made-up one")

        // `expired` assumes nothing more gets used, which is only honest at the
        // very end of a window. Mid-window it reports a freshly-reset account as
        // wasting its entire price, which is the difference between a
        // measurement and a scare number. Project at pace instead.
        let now = Date()
        func resets(elapsed: Double) -> Date {
            now.addingTimeInterval(Forecaster.weekLength * (1 - elapsed))
        }
        let tier = "default_claude_max_20x"

        expect(PlanValue.projected(weeklyPercent: 50, resetsAt: resets(elapsed: 0.5),
                                   tier: tier, now: now) == 0,
               "spending exactly on pace projects no waste")

        if let idle = PlanValue.projected(weeklyPercent: 0, resetsAt: resets(elapsed: 0.5),
                                          tier: tier, now: now) {
            expect(abs(idle - weekly) < 0.01,
                   "half the window gone with nothing spent projects the whole price wasted")
        } else {
            expect(false, "an untouched half-elapsed window projects a figure")
        }

        if let half = PlanValue.projected(weeklyPercent: 25, resetsAt: resets(elapsed: 0.5),
                                          tier: tier, now: now) {
            expect(abs(half - weekly * 0.5) < 0.01,
                   "25% spent at the halfway mark projects half the price wasted")
        } else {
            expect(false, "a half-paced window projects a figure")
        }

        expect(PlanValue.projected(weeklyPercent: 90, resetsAt: resets(elapsed: 0.5),
                                   tier: tier, now: now) == 0,
               "burning faster than pace projects no waste, never negative")

        // The case that made this necessary: a window that has just rolled over.
        // Any projection from a few minutes of data is noise, so it declines to
        // give one rather than reporting a full week wasted.
        expect(PlanValue.projected(weeklyPercent: 0, resetsAt: resets(elapsed: 0.02),
                                   tier: tier, now: now) == nil,
               "a barely-started window declines to project rather than crying waste")
        expect(PlanValue.projected(weeklyPercent: 50, resetsAt: resets(elapsed: 0.5),
                                   tier: "who-knows", now: now) == nil,
               "an unknown tier still projects nothing")
    }

    /// Cost maths. Wrong numbers here are silently wrong — nothing else in the
    /// app cross-checks them — so the rate table and the cache multipliers are
    /// pinned to published per-million-token rates rather than recalled.
    private static func pricing() {
        section("Pricing")

        guard let opus = Pricing.rate(for: "claude-opus-5") else {
            expect(false, "opus-5 has a rate"); return
        }
        expect(opus.input == 5 && opus.output == 25, "opus-5 is $5 in / $25 out per MTok")
        expect(opus.cacheRead == 0.5, "cache reads bill at 0.1x input")
        expect(opus.cacheWrite5m == 6.25, "5-minute cache writes bill at 1.25x input")
        expect(opus.cacheWrite1h == 10.0, "1-hour cache writes bill at 2x input")
        expect(opus.cacheWrite1h > opus.cacheWrite5m,
               "the 1h/5m split matters — that is why the indexer tracks them apart")

        // Date-suffixed ids appear in real transcripts; an exact-match lookup
        // would drop that model from the total entirely.
        expect(Pricing.rate(for: "claude-haiku-4-5-20251001")?.input == 1,
               "date-suffixed model ids resolve by prefix")
        expect(Pricing.rate(for: "claude-sonnet-5")?.input == 3, "sonnet-5 is $3 in per MTok")
        expect(Pricing.rate(for: "<synthetic>") == nil, "an unknown model has no rate")

        // A million output tokens on opus is exactly $25.
        var out = TokenUsage(); out.output = 1_000_000
        expect(Pricing.cost(out, model: "claude-opus-5") == 25.0, "1M output tokens costs $25")

        var reads = TokenUsage(); reads.cacheRead = 1_000_000
        expect(Pricing.cost(reads, model: "claude-opus-5") == 0.5, "1M cache reads cost $0.50")

        // Unpriced models are reported, not folded silently into the total.
        var known = TokenUsage(); known.output = 1_000_000
        var unknown = TokenUsage(); unknown.output = 1_000_000
        let mixed = Pricing.cost(["claude-opus-5": known, "<synthetic>": unknown])
        expect(mixed.total == 25.0, "an unpriced model does not inflate the total")
        expect(mixed.unpriced == ["<synthetic>"], "the unpriced model is named so the UI can say so")
    }

    /// A rolled-over window must resolve to 0 on BOTH windows.
    ///
    /// Regression guard. Handling it for the session window but not the weekly
    /// one meant that the instant the week reset, the signed-in account read as
    /// "no data", the policy marked it not-ok, and the app announced ALL-HOT
    /// while sitting on a completely fresh weekly quota.
    private static func rolledOverReadings() {
        section("Rolled-over readings")

        let now = Date()
        let past = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))
        let weekly = QuotaReader.parseLimit(
            ["kind": "weekly_all", "percent": 88, "resets_at": past], now: now)
        let session = QuotaReader.parseLimit(
            ["kind": "session", "percent": 79, "resets_at": past], now: now)

        expect(weekly?.reading == .rolledOver, "an elapsed weekly window rolls over")
        expect(session?.reading == .rolledOver, "an elapsed session window rolls over")

        // Both must behave identically — that asymmetry was the bug.
        let a = AccountReading(name: "a", label: "a", p5: 0, p7: 0,
                               ok: true, problem: nil, resets5h: nil)
        let decision = Policy.decide(current: a, accounts: [a])
        expect(decision.verdict == .stay,
               "a fresh account after a reset stays put rather than reporting ALL-HOT")

        // And the inverse: a genuinely unreadable account is still not-ok.
        let broken = AccountReading(name: "b", label: "b", p5: 0, p7: 0,
                                    ok: false, problem: "no data", resets5h: nil)
        let brokenDecision = Policy.decide(current: broken, accounts: [broken])
        expect(brokenDecision.verdict == .allHot,
               "an account with genuinely no data still reports ALL-HOT")
    }

    private static func devin() {
        section("Devin")

        // Shape taken from the v3 list-sessions schema, not invented: the fields
        // asserted here are the ones the endpoint documents as required.
        let listJSON = """
        {"items":[
          {"session_id":"s-1","url":"https://app.devin.ai/sessions/s-1",
           "org_id":"org-x","status":"running","status_detail":"working",
           "title":"fix auth flow","acus_consumed":12.5,
           "created_at":1754870000,"updated_at":1754880000,
           "tags":[],"pull_requests":[]},
          {"session_id":"s-2","url":"https://app.devin.ai/sessions/s-2",
           "org_id":"org-x","status":"suspended","status_detail":"waiting_for_user",
           "title":"port kernel","acus_consumed":3,
           "created_at":1754860000,"updated_at":1754861000,
           "tags":[],"pull_requests":[]},
          {"session_id":"s-3","url":"https://app.devin.ai/sessions/s-3",
           "org_id":"org-x","status":"exit","status_detail":"finished",
           "acus_consumed":4.25,
           "created_at":1754850000,"updated_at":1754851000,
           "tags":[],"pull_requests":[],"is_archived":true}
        ],"end_cursor":null,"has_next_page":false,"total":3}
        """

        let sessions = (try? DevinClient.parse(Data(listJSON.utf8))) ?? []
        expect(sessions.count == 3, "parses every item in the list envelope")

        guard let first = sessions.first else {
            expect(false, "list must yield a first session")
            return
        }
        expect(first.id == "s-1", "reads session_id")
        expect(first.title == "fix auth flow", "reads title")
        expect(first.status == .running, "maps status 'running'")
        expect(first.statusDetail == "working", "keeps status_detail for the row")
        expect(abs(first.acusConsumed - 12.5) < 0.001, "reads fractional acus_consumed")
        expect(first.url?.host == "app.devin.ai", "reads url")

        // Title is optional in the schema, so the row has to have a fallback that
        // is not an empty string -- a blank row reads as a broken fetch.
        expect(sessions[2].title == nil, "tolerates a session with no title")
        expect(!sessions[2].displayTitle.isEmpty, "an untitled session still has a label")
        expect(sessions[2].isArchived, "reads is_archived")
        expect(!first.isArchived, "is_archived defaults to false when absent")

        // Every documented status must map. An unrecognised one must not throw
        // the whole list away -- one new status value upstream would otherwise
        // blank the entire section.
        for raw in ["new", "claimed", "running", "exit", "error", "suspended", "resuming"] {
            expect(DevinSession.Status(api: raw) != .unknown, "maps documented status '\(raw)'")
        }
        expect(DevinSession.Status(api: "teleporting") == .unknown, "an unknown status degrades")

        expect(DevinSession.Status.running.isActive, "running counts as active")
        expect(DevinSession.Status.resuming.isActive, "resuming counts as active")
        expect(DevinSession.Status.claimed.isActive, "claimed counts as active")
        expect(!DevinSession.Status.suspended.isActive, "suspended is not active")
        expect(!DevinSession.Status.exit.isActive, "exit is not active")

        // The schema says integer timestamps but does not say which unit, and the
        // same ambiguity already bit the credential parser. Both must land in 2025+.
        let asSeconds = DevinClient.date(from: 1754870000)
        let asMillis = DevinClient.date(from: 1754870000000)
        expect(abs(asSeconds.timeIntervalSince(asMillis)) < 1,
               "millisecond and second timestamps resolve to the same instant")

        // MARK: Summary

        let now = Date(timeIntervalSince1970: 1754890000)
        let summary = DevinUsage.summarise(sessions, allowance: nil, now: now)
        expect(summary.active == 1, "counts one active session")
        expect(summary.asleep == 1, "counts one suspended session")
        expect(abs(summary.acus - 19.75) < 0.001, "sums acus across all sessions")
        expect(summary.percent == nil, "no allowance configured means no percentage")

        let gauged = DevinUsage.summarise(sessions, allowance: 100, now: now)
        expect(gauged.percent.map { abs($0 - 19.75) < 0.001 } == true,
               "an allowance turns consumption into a percentage")

        // Over-spend must report honestly rather than pin at 100: the whole point
        // of the gauge is to show that a limit was blown through.
        let over = DevinUsage.summarise(sessions, allowance: 10, now: now)
        expect((over.percent ?? 0) > 100, "spending past the allowance reports over 100%")

        // Sessions outside the period must not be counted, or the number only
        // ever grows and stops meaning anything.
        let periodStart = Date(timeIntervalSince1970: 1754865000)
        let scoped = DevinUsage.summarise(sessions, allowance: nil, now: now, since: periodStart)
        expect(abs(scoped.acus - 12.5) < 0.001, "only sessions inside the period are summed")

        // The invariant borrowed from the quota gauge: nothing-configured and
        // nothing-happened must not render identically, because a zeroed gauge
        // reads as "plenty left".
        let empty = DevinUsage.summarise([], allowance: nil, now: now)
        expect(empty.acus == 0 && empty.active == 0, "an empty org summarises to zeroes")
        expect(empty.isEmpty, "an empty org is distinguishable from an unconfigured one")

        // MARK: Client failures

        expect(DevinClient.Failure.unauthorized.short == "key rejected",
               "a 403 says the key was rejected, not that usage is zero")
        expect(DevinClient.Failure.noOrg.short.contains("org"),
               "a missing org id names the org id")
        expect((try? DevinClient.parse(Data("not json".utf8))) == nil,
               "unreadable JSON throws rather than yielding an empty list")

        // An empty envelope is a real answer and must parse, not throw -- that is
        // exactly what this org returns today.
        let emptyEnvelope = #"{"items":[],"end_cursor":null,"has_next_page":false,"total":0}"#
        expect((try? DevinClient.parse(Data(emptyEnvelope.utf8)))?.isEmpty == true,
               "an empty org parses to an empty list, not an error")
    }

    /// The access control list on a credentials item Headroom had to create.
    ///
    /// The prompt this guards against is the one that says *"security wants to
    /// access key Claude Code-credentials"* -- `security` being the command line
    /// tool Claude Code itself shells out to. It appears because a keychain item
    /// created by `SecItemAdd` trusts exactly one binary: the one that created
    /// it. On a swap where Claude Code had no item of its own, that is Headroom,
    /// so the next Claude Code read is an untrusted read and macOS stops to ask.
    ///
    /// "Always Allow" does not survive this, because the next swap through the
    /// same path builds a brand new item with a brand new ACL.
    ///
    /// Run against a scratch keychain rather than the login one. This test
    /// creates and reads credentials items, and doing that for real would put it
    /// next to -- and one API mistake away from -- the token the user is signed
    /// in with.
    /// Annotated deprecated purely to silence the legacy `SecKeychain*` calls
    /// below: setting an ACL has no modern replacement, so the whole family is
    /// deprecated with nothing to migrate to. Swift only suppresses those inside
    /// an equally deprecated context, which costs one warning at the call site --
    /// cheaper than the nine it silences.
    @available(macOS, deprecated: 10.10)
    private static func keychainACL() {
        section("Keychain ACL")

        guard let scratch = scratchKeychain() else {
            expect(false, "a scratch keychain can be created")
            return
        }
        defer { destroyScratchKeychain(scratch) }

        let service = "headroom-selftest-\(UUID().uuidString)"
        do {
            try Keychain.writeTargeting(
                Data("not-a-real-token".utf8), service: service,
                sharedWithClaudeCode: true, in: scratch.keychain)
        } catch {
            expect(false, "the credentials item is created: \(error)")
            return
        }

        // `SecItemAdd` honours the default keychain, but `SecItemCopyMatching`
        // searches the *search list*, which setting a default does not join. The
        // scratch keychain has to be named explicitly or the item that was just
        // written reads back as missing.
        var ref: CFTypeRef?
        let found = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Keychain.defaultAccount,
            kSecMatchSearchList as String: [scratch.keychain] as CFArray,
            kSecReturnRef as String: true,
        ] as CFDictionary, &ref)
        guard found == errSecSuccess, let item = ref else {
            expect(false, "the created item can be found again (status \(found))")
            return
        }

        var access: SecAccess?
        // swiftlint:disable:next force_cast
        let copied = SecKeychainItemCopyAccess((item as! SecKeychainItem), &access)
        guard copied == errSecSuccess, let access else {
            expect(false, "the item carries an access control list (status \(copied))")
            return
        }

        var aclsRef: CFArray?
        guard SecAccessCopyACLList(access, &aclsRef) == errSecSuccess,
              let acls = aclsRef as? [SecACL]
        else {
            expect(false, "the access control list can be read back")
            return
        }

        // A SecAccess holds one ACL per authorization tag, and they do not all
        // mean the same thing: the encrypt ACL is open to everything by design,
        // because writing a secret nobody can read back is harmless. Only the
        // decrypt ACL decides who reads the token without a prompt, so it is the
        // only one worth asserting on -- an earlier version of this test looked
        // at all of them and called the item world-readable when it was not.
        var trusted: Set<String> = []
        var allowsEveryApplication = false
        var foundDecryptACL = false
        for acl in acls {
            guard let authorizations = SecACLCopyAuthorizations(acl) as? [String],
                  authorizations.contains(kSecACLAuthorizationDecrypt as String)
            else { continue }
            foundDecryptACL = true

            var apps: CFArray?
            var description: CFString?
            var selector = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &apps, &description, &selector) == errSecSuccess
            else { continue }
            // A nil application list on the decrypt ACL is "allow all
            // applications": every process on the machine reads the token freely.
            guard let apps = apps as? [SecTrustedApplication] else {
                allowsEveryApplication = true
                continue
            }
            for app in apps {
                var data: CFData?
                guard SecTrustedApplicationCopyData(app, &data) == errSecSuccess,
                      let data = data as Data?
                else { continue }
                let raw = String(decoding: data, as: UTF8.self)
                trusted.insert(raw.trimmingCharacters(in: CharacterSet(charactersIn: "\0")))
            }
        }

        expect(foundDecryptACL, "the item has a decrypt ACL to inspect")

        expect(trusted.contains("/usr/bin/security"),
               "the ACL trusts /usr/bin/security, which is how Claude Code reads the token")
        expect(!allowsEveryApplication,
               "the ACL names specific binaries rather than allowing every application")
        expect(!trusted.isEmpty,
               "the ACL is a real trust list, not an empty one")

        // Everything above is Headroom marking its own homework: it asserts that
        // the ACL Headroom wrote says what Headroom meant it to say. That cannot
        // catch a wrong belief about what macOS enforces, and a wrong belief about
        // exactly that is what shipped the bug.
        //
        // So the check that actually decides the question runs the real tool, out
        // of process, exactly as Claude Code does. If it comes back blocked -- a
        // refusal, or a dialog we waited out -- the user gets a password prompt on
        // every Claude Code start, whatever the ACL looks like from in here.
        let readBack = Keychain.securityToolCanRead(
            service: service, keychainPath: scratch.path.path)
        expect(readBack == Data("not-a-real-token".utf8),
               "/usr/bin/security really reads the item back, out of process, without a prompt")
    }

    /// What the partition list does, pinned so a wrong belief cannot ship twice.
    ///
    /// The fix this file guards was once written on the theory that macOS ANDs
    /// the decrypt ACL against an independent partition list, so an item had to
    /// carry `apple-tool:` before `/usr/bin/security` could read it. Measurement
    /// says otherwise: with the tool on the trusted-application list, the item is
    /// readable with a partition list that omits `apple-tool:`, and with no
    /// partition ACL at all.
    ///
    /// That mattered because it was load-bearing in the wrong direction. Health
    /// detection required `apple-tool:`, and `security add-generic-password -U`
    /// -- how Claude Code writes a refreshed token, several times a day -- clears
    /// the partition list while leaving the trusted-application list intact. A
    /// healthy machine would have reported itself broken within hours, and
    /// "repaired" an ACL that was already correct on every swap.
    ///
    /// If a future macOS starts enforcing partitions, this test fails and the
    /// belief gets revisited. That is the entire point of it.
    @available(macOS, deprecated: 10.10)
    private static func keychainPartitionListIsNotAGate() {
        section("Keychain partition list")

        guard let scratch = scratchKeychain() else {
            expect(false, "a scratch keychain can be created")
            return
        }
        defer { destroyScratchKeychain(scratch) }

        let service = "headroom-selftest-\(UUID().uuidString)"
        var reader: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(Keychain.claudeCodeReaderPath, &reader)
                == errSecSuccess, let reader else {
            expect(false, "/usr/bin/security can be described as a trusted application")
            return
        }
        var access: SecAccess?
        guard SecAccessCreate(service as CFString, [reader] as CFArray, &access) == errSecSuccess,
              let access else {
            expect(false, "an ACL trusting the tool can be built")
            return
        }

        // A partition list that deliberately does NOT admit the security tool.
        // If partitions were a gate, this item would be unreadable by it.
        guard let description = encodePartitionIDs(["cdhash:0000000000000000000000000000000000000000"])
        else {
            expect(false, "a partition list can be encoded")
            return
        }
        var acl: SecACL?
        guard SecACLCreateWithSimpleContents(
                access, nil, description, SecKeychainPromptSelector(), &acl) == errSecSuccess,
              let acl,
              SecACLUpdateAuthorizations(acl, [kSecACLAuthorizationPartitionID] as CFArray)
                == errSecSuccess else {
            expect(false, "a partition ACL can be attached")
            return
        }

        guard SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Keychain.defaultAccount,
            kSecValueData as String: Data("partition-probe".utf8),
            kSecAttrAccess as String: access,
            kSecUseKeychain as String: scratch.keychain,
        ] as CFDictionary, nil) == errSecSuccess else {
            expect(false, "the probe item can be created")
            return
        }

        expect(Keychain.securityToolCanRead(service: service, keychainPath: scratch.path.path)
                == Data("partition-probe".utf8),
               "a partition list that omits apple-tool: does not stop /usr/bin/security — "
               + "the trusted-application list is the only gate")
    }

    /// Hex(UTF-8 XML plist `{Partitions: [...]}`), the encoding `security`'s own
    /// source uses for a partition ACL's description field.
    ///
    /// Lives only in the test: nothing in the product writes a partition list any
    /// more, because the natural state of an item that has never had one is
    /// "unrestricted", and writing one could only ever narrow that.
    private static func encodePartitionIDs(_ partitions: [String]) -> CFString? {
        guard let xml = try? PropertyListSerialization.data(
            fromPropertyList: ["Partitions": partitions], format: .xml, options: 0)
        else { return nil }
        return xml.map { String(format: "%02x", $0) }.joined() as CFString
    }

    /// The access control list on a credentials item that already existed.
    ///
    /// Fixing only the create path would fix nobody already suffering: their item
    /// exists, so every write takes `SecItemUpdate`, which leaves the ACL exactly
    /// as wrong as it was. The prompt would keep arriving forever on any machine
    /// where the bad item had already been made -- which is every machine that
    /// has the bug.
    ///
    /// So a write also repairs the ACL it finds, by replacing the item rather
    /// than editing its ACL in place. That distinction is what makes the repair
    /// free: deleting a generic password needs no authorisation, so there is no
    /// dialog on any path, including the background one.
    @available(macOS, deprecated: 10.10)
    private static func keychainACLRepair() {
        section("Keychain ACL repair")

        guard let scratch = scratchKeychain() else {
            expect(false, "a scratch keychain can be created")
            return
        }
        defer { destroyScratchKeychain(scratch) }

        // The "before" state: an item trusting only the app that made it, which
        // is what the buggy build produced.
        //
        // The ACL is built explicitly rather than left to SecItemAdd's default so
        // that this binary is trusted to *change* it. Changing an ACL you are not
        // trusted for needs authorisation, and `SecKeychainItemSetAccess` does not
        // return an error when it is not allowed to ask -- it blocks forever. The
        // real repair on a real machine is allowed to cost one prompt; a self test
        // that hangs the build is not.
        let service = "headroom-selftest-\(UUID().uuidString)"
        var me: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me else {
            expect(false, "the test binary can describe itself as a trusted application")
            return
        }
        var ownAccess: SecAccess?
        guard SecAccessCreate(service as CFString, [me] as CFArray, &ownAccess) == errSecSuccess,
              let ownAccess
        else {
            expect(false, "an ACL trusting only this binary can be built")
            return
        }
        let legacy: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Keychain.defaultAccount,
            kSecValueData as String: Data("stale-token".utf8),
            kSecAttrAccess as String: ownAccess,
        ]
        var planted = legacy
        planted[kSecUseKeychain as String] = scratch.keychain
        guard SecItemAdd(planted as CFDictionary, nil) == errSecSuccess else {
            expect(false, "a legacy item can be planted to repair")
            return
        }

        guard let before = decryptTrustList(service: service, in: scratch.keychain) else {
            expect(false, "the planted item's ACL can be read")
            return
        }
        expect(!before.trusted.contains(Keychain.claudeCodeReaderPath),
               "the planted item starts out not trusting \(Keychain.claudeCodeReaderPath)")

        expect(Keychain.claudeCodeCanReadSilently(
            service: service, in: scratch.keychain) == false,
               "the planted item is reported as blocked before anything repairs it")

        // The background path -- auto swap -- writing non-interactively.
        //
        // This is the case the previous design could not serve. Repair used to
        // mean `SecKeychainItemSetAccess`, which needs an authorisation this
        // process may not hold and blocks on a dialog rather than failing when it
        // does not, so a non-interactive write had to skip it. A user with auto
        // swap on and no manual swaps therefore sat behind a broken ACL forever.
        //
        // Replacing the item instead of editing its ACL costs no authorisation at
        // all -- deleting a generic password is not gated by the decrypt ACL --
        // so the repair now reaches the background path too, and needs no dialog
        // on any path.
        do {
            try Keychain.writeTargeting(Data("fresh-token".utf8), service: service,
                                        allowInteraction: false,
                                        sharedWithClaudeCode: true, in: scratch.keychain)
        } catch {
            expect(false, "a non-interactive write to the existing item succeeds: \(error)")
            return
        }

        guard let after = decryptTrustList(service: service, in: scratch.keychain) else {
            expect(false, "the item's ACL can still be read")
            return
        }
        expect(after.trusted.contains(Keychain.claudeCodeReaderPath),
               "a non-interactive write repairs the ACL, with no dialog and no authorisation")
        expect(!after.allowsEveryApplication,
               "the item is never widened to every application")

        // The verdict that counts, and the one that also proves the write's own
        // payload survived the repair: the tool Claude Code shells out to reads
        // the new secret back, out of process.
        expect(Keychain.securityToolCanRead(service: service, keychainPath: scratch.path.path)
                == Data("fresh-token".utf8),
               "/usr/bin/security reads the repaired item without a prompt")

        // The flip side of the design, worth asserting because breaking it is
        // silent and slow-acting: Headroom deliberately holds no ACL membership
        // of its own, so a direct in-process read is refused. If this ever
        // starts succeeding, something has put Headroom back on the trust list,
        // and that entry is a code hash which goes stale on the next rebuild --
        // the exact rot this design removes. Reading through the tool is how
        // Headroom is meant to get at the secret, and `read` does.
        var direct: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Keychain.defaultAccount,
            kSecMatchSearchList as String: [scratch.keychain] as CFArray,
            kSecReturnData as String: true,
        ] as CFDictionary, &direct)
        expect(status != errSecSuccess,
               "Headroom is not on the repaired item's ACL — it reads through the tool instead")

        expect(Keychain.claudeCodeCanReadSilently(
            service: service, in: scratch.keychain) == true,
               "the repaired item is reported healthy")

        expect(Keychain.claudeCodeCanReadSilently(
            service: "headroom-selftest-absent-\(UUID().uuidString)",
            in: scratch.keychain) == nil,
               "a missing item reads as absent rather than blocked -- never signing in is not a fault")
    }

    /// The other direction, which had no test and no detection at all.
    ///
    /// After a fresh `claude login` the item is created by `/usr/bin/security`,
    /// whose ACL names only itself. Claude Code is fine; Headroom is locked out.
    /// Its swap path reads the outgoing credential before overwriting it and
    /// refuses the swap when it cannot -- correctly, since overwriting a token it
    /// could not first copy would destroy an account -- so the user sees
    /// "refusing to swap — cannot read the current account" and no amount of
    /// waiting fixes it.
    ///
    /// Reading through the same tool is what closes this: Headroom needs no ACL
    /// membership of its own, so an item that admits `security` admits both.
    @available(macOS, deprecated: 10.10)
    private static func keychainToolCreatedItemIsUsable() {
        section("Keychain item created by security(1)")

        guard let scratch = scratchKeychain() else {
            expect(false, "a scratch keychain can be created")
            return
        }
        defer { destroyScratchKeychain(scratch) }

        let service = "headroom-selftest-\(UUID().uuidString)"
        var reader: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(Keychain.claudeCodeReaderPath, &reader)
                == errSecSuccess, let reader,
              let access = { () -> SecAccess? in
                  var a: SecAccess?
                  guard SecAccessCreate(service as CFString, [reader] as CFArray, &a)
                          == errSecSuccess else { return nil }
                  return a
              }() else {
            expect(false, "an ACL naming only the security tool can be built")
            return
        }
        guard SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Keychain.defaultAccount,
            kSecValueData as String: Data("token-from-claude-login".utf8),
            kSecAttrAccess as String: access,
            kSecUseKeychain as String: scratch.keychain,
        ] as CFDictionary, nil) == errSecSuccess else {
            expect(false, "an item owned only by the security tool can be planted")
            return
        }

        expect(Keychain.claudeCodeCanReadSilently(service: service, in: scratch.keychain) == true,
               "an item created by security(1) is healthy from Claude Code's side")

        // The write Headroom performs when swapping away from this account. It
        // must succeed even though Headroom cannot decrypt the item: the encrypt
        // authorisation is open, which is the property that keeps every write
        // path prompt-free.
        do {
            try Keychain.writeTargeting(Data("swapped-in".utf8), service: service,
                                        allowInteraction: false,
                                        sharedWithClaudeCode: true, in: scratch.keychain)
        } catch {
            expect(false, "Headroom can overwrite an item it is not trusted to read: \(error)")
            return
        }

        expect(Keychain.securityToolCanRead(service: service, keychainPath: scratch.path.path)
                == Data("swapped-in".utf8),
               "the swapped-in token is what security(1) reads back")
    }

    // MARK: Harness

    /// A throwaway keychain, so no test ever writes near the real login one.
    ///
    /// Unlocked explicitly with the password it was just created with. Without
    /// this, changing an item's ACL makes macOS ask the user to unlock a keychain
    /// whose password is a UUID generated in this function and never shown to
    /// anyone -- an unanswerable dialog, over whatever they were doing.
    @available(macOS, deprecated: 10.10)
    private static func scratchKeychain() -> (keychain: SecKeychain, path: URL)? {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "headroom-acl-\(UUID().uuidString).keychain")
        let password = Array(UUID().uuidString.utf8)
        var keychain: SecKeychain?
        guard SecKeychainCreate(
                path.path, UInt32(password.count), password, false, nil, &keychain)
                == errSecSuccess,
              let keychain
        else { return nil }
        guard SecKeychainUnlock(keychain, UInt32(password.count), password, true)
                == errSecSuccess
        else {
            SecKeychainDelete(keychain)
            try? FileManager.default.removeItem(at: path)
            return nil
        }
        return (keychain, path)
    }

    /// The keychain ACL cases, behind one deprecated door.
    ///
    /// Everything below touches the legacy `SecKeychain*` family, which has no
    /// modern replacement for reading or setting an ACL. Swift only silences a
    /// deprecation warning inside an equally deprecated context, so the warnings
    /// have to surface at whichever call site crosses the line. Funnelling the
    /// cases through here makes that exactly one, instead of one per case.
    @available(macOS, deprecated: 10.10)
    private static func keychainAccessControl() {
        withoutUserInteraction {
            keychainACL()
            keychainACLRepair()
            keychainToolCreatedItemIsUsable()
            keychainPartitionListIsNotAGate()
        }
    }

    /// Runs `body` with macOS forbidden from putting up any keychain dialog.
    ///
    /// A belt to the unlock braces above. These tests exercise the exact
    /// operations that prompt, and a self test that can interrupt the user with a
    /// password dialog is worse than no self test. With interaction refused, an
    /// operation that would have prompted fails instead, and the check that
    /// depended on it fails loudly rather than silently waiting on a human.
    @available(macOS, deprecated: 10.10)
    private static func withoutUserInteraction(_ body: () -> Void) {
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        body()
    }

    @available(macOS, deprecated: 10.10)
    private static func destroyScratchKeychain(_ scratch: (keychain: SecKeychain, path: URL)) {
        SecKeychainDelete(scratch.keychain)
        try? FileManager.default.removeItem(at: scratch.path)
    }

    /// Who may read the secret without a prompt, per the decrypt ACL.
    @available(macOS, deprecated: 10.10)
    private static func decryptTrustList(
        service: String,
        in keychain: SecKeychain
    ) -> (trusted: Set<String>, allowsEveryApplication: Bool)? {
        var ref: CFTypeRef?
        guard SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Keychain.defaultAccount,
            kSecMatchSearchList as String: [keychain] as CFArray,
            kSecReturnRef as String: true,
        ] as CFDictionary, &ref) == errSecSuccess,
              let item = ref,
              CFGetTypeID(item) == SecKeychainItemGetTypeID()
        else { return nil }

        var access: SecAccess?
        // swiftlint:disable:next force_cast
        guard SecKeychainItemCopyAccess((item as! SecKeychainItem), &access) == errSecSuccess,
              let access
        else { return nil }

        var aclsRef: CFArray?
        guard SecAccessCopyACLList(access, &aclsRef) == errSecSuccess,
              let acls = aclsRef as? [SecACL]
        else { return nil }

        var trusted: Set<String> = []
        var allowsEveryApplication = false
        for acl in acls {
            guard let authorizations = SecACLCopyAuthorizations(acl) as? [String],
                  authorizations.contains(kSecACLAuthorizationDecrypt as String)
            else { continue }

            var apps: CFArray?
            var description: CFString?
            var selector = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &apps, &description, &selector) == errSecSuccess
            else { continue }
            guard let apps = apps as? [SecTrustedApplication] else {
                allowsEveryApplication = true
                continue
            }
            for app in apps {
                var data: CFData?
                guard SecTrustedApplicationCopyData(app, &data) == errSecSuccess,
                      let data = data as Data?
                else { continue }
                trusted.insert(String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0")))
            }
        }
        return (trusted, allowsEveryApplication)
    }

    private static func section(_ name: String) {
        print("")
        print(name)
    }

    private static func expect(_ condition: Bool, _ description: String) {
        checks += 1
        if condition {
            print("  ok    \(description)")
        } else {
            failures += 1
            print("  FAIL  \(description)")
        }
    }
}
