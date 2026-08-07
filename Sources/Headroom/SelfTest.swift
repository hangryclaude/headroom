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
        rolledOverReadings()
        pricing()

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

    // MARK: Harness

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
