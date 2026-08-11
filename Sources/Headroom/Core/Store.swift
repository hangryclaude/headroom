import Foundation
import Observation
import SwiftUI

enum MenuBarMode: String, CaseIterable, Identifiable {
    case weekly      // "16%"  — the budget
    case session     // "79%"  — the throttle
    case both        // "16% · 79%"
    case countdown   // "2:48"
    case dot         // colour only

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weekly:    return "Weekly percentage"
        case .session:   return "Session percentage"
        case .both:      return "Weekly · session"
        case .countdown: return "Time to session reset"
        case .dot:       return "Indicator only"
        }
    }
}

struct Settings {
    var menuBarMode: MenuBarMode
    var autoSwap: Bool
    var notifyOnDecision: Bool

    static var current: Settings {
        let d = UserDefaults.standard
        return Settings(
            menuBarMode: MenuBarMode(rawValue: d.string(forKey: "menuBarMode") ?? "") ?? .weekly,
            // Notify-then-confirm by default. An earlier tool defaulted to automatic,
            // but it could not see running sessions; Headroom can, and yanking
            // credentials out from under a live turn is the one failure that
            // actually costs work.
            autoSwap: d.object(forKey: "autoSwap") as? Bool ?? false,
            notifyOnDecision: d.object(forKey: "notifyOnDecision") as? Bool ?? true
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(menuBarMode.rawValue, forKey: "menuBarMode")
        d.set(autoSwap, forKey: "autoSwap")
        d.set(notifyOnDecision, forKey: "notifyOnDecision")
    }
}

/// Live usage for one stored account, with the age that makes it honest.
struct AccountUsage: Equatable {
    var p5: Int?
    var p7: Int?
    var fetchedAt: Date?
    var error: String?
    var resets5h: Date?

    var isUsable: Bool { p5 != nil && p7 != nil && error == nil }
}

@MainActor
@Observable
final class Store {
    private(set) var quota: QuotaSnapshot?
    private(set) var quotaError: String?
    private(set) var verdict: SwapVerdict = .clear
    private(set) var identity: Identity?
    private(set) var now: Date = Date()

    private(set) var accounts: [StoredAccount] = []
    private(set) var activeAccountName: String?
    private(set) var usage: [String: AccountUsage] = [:]
    private(set) var decision: Decision = Decision(
        verdict: .noAccounts, target: nil, why: "no accounts saved yet")

    private(set) var tokens24h = TokenUsage()
    /// Per-model, so cost can be priced at each model's own rate.
    private(set) var tokensByModel24h: [String: TokenUsage] = [:]
    private(set) var burnPerMinute: Double = 0
    private(set) var lastSwapError: String?
    /// What auto mode last did, so the popover can say so rather than the
    /// account silently changing under the user.
    private(set) var lastAutoSwap: (name: String, at: Date)?

    var settings: Settings { didSet { settings.save() } }

    private let reader = QuotaReader()
    private let sessions = SessionGuard()
    private let identities = IdentityReader()
    private let indexer = TranscriptIndexer()
    let vault = AccountVault()
    private let usageClient = UsageClient()
    private let refresher = TokenRefresher()
    /// Why an account's token could not be renewed, so the row can say something
    /// truer than "expired".
    private var refreshProblem: [String: String] = [:]

    private var timer: Timer?
    private var tick = 0
    private var isFetchingUsage = false
    private var isIndexing = false
    /// Set while a token redemption is in flight.
    ///
    /// `usableToken` suspends across the network call, and `Store` is
    /// `@MainActor`, so that suspension hands the main actor back and a click on
    /// an account row can run a whole swap inside the window. The refresh then
    /// completes and writes a rotated credential belonging to an account that is
    /// no longer the one installed. Swapping is blocked for the duration instead.
    private var isRefreshingToken = false
    private var lastAutoSwapAttempt: Date?

    /// Minimum gap between automatic swaps. Without it a flapping verdict — or
    /// a target that turns out to be just as hot — could cycle accounts every
    /// tick, and each swap costs a Keychain write and a config rewrite.
    private static let autoSwapCooldown: TimeInterval = 5 * 60

    /// Matches an earlier tool's cache TTL: the endpoint is not free and the numbers
    /// do not move fast enough to justify hammering it.
    private static let usageTTL: TimeInterval = 12 * 60

    init() {
        settings = .current
        refresh()
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
        Task { await refreshUsage() }
        refreshTokens()
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func onTick() {
        now = Date()
        tick += 1
        if tick % 5 == 0 { refresh(); evaluateAutoSwap() }
        if tick % 30 == 0 { refreshTokens() }
        if tick % 60 == 0 { Task { await refreshUsage() } }
    }

    // MARK: Local reads

    func refresh() {
        now = Date()
        do {
            quota = try reader.read(now: now)
            quotaError = nil
        } catch {
            quota = nil
            quotaError = String(describing: error)
        }
        verdict = sessions.verdict()
        identity = identities.read()
        accounts = vault.accounts()
        activeAccountName = vault.activeAccount()?.name
        // Re-read rather than trust our own last write: `/model` changes this
        // file too, so a cached value would show the picker disagreeing with the
        // session the user is actually in.
        modelRaw = ModelSetting.raw()
        recomputeDecision()
    }

    /// What `~/.claude/settings.json` says, verbatim. nil when unset.
    private(set) var modelRaw: String?

    /// nil when the stored value is one Claude Code accepts but the picker does
    /// not offer -- `opusplan`, `sonnet[1m]`. The picker shows `modelRaw` then.
    var model: ClaudeModel? { modelRaw.flatMap(ClaudeModel.init(rawValue:)) }

    func setModel(_ model: ClaudeModel?) {
        guard let model else { return }
        do {
            try ModelSetting.set(model)
            modelRaw = model.rawValue
        } catch {
            // Same surface as a failed swap: the popover already has one place
            // to say "the thing you clicked did not happen".
            lastSwapError = String(describing: error)
        }
    }

    /// The transcript scan touches hundreds of files, so it never runs on main.
    private func refreshTokens() {
        // Without this the 30s timer stacks detached tasks that all block on the
        // indexer's lock, pinning cooperative-pool threads for as long as a scan
        // takes.
        guard !isIndexing else { return }
        isIndexing = true
        let indexer = self.indexer
        let now = self.now
        Task.detached(priority: .utility) {
            indexer.refresh(now: now)
            let byModel = indexer.usage(since: now.addingTimeInterval(-24 * 3600), now: now)
            let day = byModel.values.reduce(into: TokenUsage()) { $0 += $1 }
            let rate = indexer.burnRate(window: 3600, now: now)
            await MainActor.run {
                self.tokens24h = day
                self.tokensByModel24h = byModel
                self.burnPerMinute = rate
                self.isIndexing = false
            }
        }
    }

    // MARK: Per-account usage

    /// Asks the server for every stored account's quota.
    ///
    /// The active account is read from disk instead -- Claude Code has already
    /// fetched it, so spending a request on it would be waste.
    func refreshUsage(force: Bool = false) async {
        guard !isFetchingUsage else { return }
        isFetchingUsage = true
        defer { isFetchingUsage = false }

        for account in accounts where account.name != activeAccountName {
            let cached = usage[account.name]
            if !force, let fetchedAt = cached?.fetchedAt,
               now.timeIntervalSince(fetchedAt) < Self.usageTTL { continue }

            guard let token = await usableToken(for: account) else {
                usage[account.name] = AccountUsage(error: refreshProblem[account.name] ?? "needs login")
                continue
            }

            do {
                let snapshot: QuotaSnapshot
                do {
                    snapshot = try await usageClient.fetch(accessToken: token)
                } catch UsageClient.Failure.tokenExpired {
                    // The server is authoritative. A token can be revoked before
                    // its stored expiry, so force one rotation and retry instead
                    // of leaving the row stuck at "token expired" until the
                    // local timestamp catches up.
                    guard let renewed = await usableToken(for: account, forceRefresh: true) else {
                        usage[account.name] = AccountUsage(
                            fetchedAt: Date(),
                            error: refreshProblem[account.name] ?? "needs login"
                        )
                        continue
                    }
                    snapshot = try await usageClient.fetch(accessToken: renewed)
                }
                usage[account.name] = AccountUsage(
                    p5: snapshot.session?.reading.percent,
                    p7: snapshot.weekly?.reading.percent,
                    fetchedAt: Date(),
                    error: nil,
                    resets5h: snapshot.session?.resetsAt
                )
            } catch let failure as UsageClient.Failure {
                // A failed fetch must never render as 0% -- an empty gauge reads
                // as "plenty left", which is the opposite of what it means.
                usage[account.name] = AccountUsage(
                    fetchedAt: Date(),
                    error: failure.short
                )
            } catch {
                usage[account.name] = AccountUsage(
                    fetchedAt: Date(), error: error.localizedDescription)
            }
        }
        recomputeDecision()
    }

    /// A live access token for an inactive account, refreshing it first if it has
    /// aged out in the vault.
    ///
    /// Without this, a stored account goes dark after a few hours and its row
    /// reads "token expired" forever -- which defeats the whole point, since the
    /// account you most want to switch to is the one you have not been using.
    private func usableToken(for account: StoredAccount, forceRefresh: Bool = false) async -> String? {
        guard let stored = vault.credentials(for: account) else { return nil }
        if !forceRefresh, let expiresAt = stored.expiresAt,
           expiresAt.timeIntervalSinceNow > TokenRefresher.skew {
            refreshProblem[account.name] = nil
            return stored.accessToken
        }

        let vault = self.vault
        isRefreshingToken = true
        defer { isRefreshingToken = false }

        switch await refresher.refreshIfNeeded(
            stored,
            directory: vault.directory(for: account),
            force: forceRefresh,
            persist: { try vault.replaceCredentials($0, for: account) }
        ) {
        case .stillValid:
            refreshProblem[account.name] = nil
            return stored.accessToken
        case .refreshed(let updated):
            // Already persisted, under the lock.
            refreshProblem[account.name] = nil
            return updated.accessToken
        case .rateLimited:
            // Transient, and explicitly not a dead account. Keep using whatever
            // token we have; the fetch may still fail, and that is fine.
            refreshProblem[account.name] = "rate limited"
            return stored.accessToken
        case .needsLogin(let why):
            refreshProblem[account.name] = "needs login"
            Diag.log("refresh: \(account.name) needs login — \(why)")
            return nil
        case .busy:
            refreshProblem[account.name] = nil
            return stored.accessToken
        case .failed(let why):
            refreshProblem[account.name] = "refresh failed"
            Diag.log("refresh: \(account.name) failed — \(why)")
            return stored.accessToken
        }
    }

    // MARK: Forecast

    /// Weekly pacing. Nil until there is a weekly window with a reset time.
    var pace: Pace? {
        guard let weekly = quota?.weekly,
              let percent = weekly.reading.percent,
              let resetsAt = weekly.resetsAt
        else { return nil }
        return Forecaster.pace(weeklyPercent: percent, resetsAt: resetsAt, now: now)
    }

    var paceVerdict: String? {
        pace.map { Forecaster.verdict($0, now: now) }
    }

    /// When the 5-hour window runs out, if it will before it resets.
    var sessionWall: Date? {
        guard let session = quota?.session,
              let percent = session.reading.percent,
              let resetsAt = session.resetsAt
        else { return nil }
        return Forecaster.sessionWall(percent: percent, resetsAt: resetsAt, now: now)
    }

    // MARK: Policy

    private func recomputeDecision() {
        let readings = accounts.map { reading(for: $0) }
        let current = activeAccountName.flatMap { name in readings.first { $0.name == name } }
        decision = Policy.decide(current: current, accounts: readings)
    }

    /// A reading as a number, with a rolled-over window resolving to 0.
    private static func resolved(_ reading: Reading?) -> Int? {
        switch reading {
        case .live(let p):  return p
        case .rolledOver:   return 0
        case .unknown, nil: return nil
        }
    }

    private func reading(for account: StoredAccount) -> AccountReading {
        if account.name == activeAccountName {
            // The signed-in account's numbers come from the file Claude Code
            // already refreshed, which is both free and the freshest source.
            // Both windows resolve a rolled-over reading to 0, for the reason
            // in `displayPercent`: the cache only goes stale when Claude Code
            // has not contacted the server, and it contacts on every request —
            // so a reset window with a stale cache has had nothing spent in it.
            //
            // Handling this for the session window but not the weekly one meant
            // that the moment the week rolled over, the signed-in account read
            // as "no data", went `ok: false`, and the policy announced ALL-HOT
            // while sitting on a completely fresh quota.
            let p5 = Self.resolved(quota?.session?.reading)
            let p7 = Self.resolved(quota?.weekly?.reading)
            return AccountReading(
                name: account.name,
                label: account.label,
                p5: p5 ?? 0,
                p7: p7 ?? 0,
                ok: p5 != nil && p7 != nil,
                problem: (p5 == nil || p7 == nil) ? "no data" : nil,
                resets5h: quota?.session?.resetsAt
            )
        }

        let live = usage[account.name]
        return AccountReading(
            name: account.name,
            label: account.label,
            p5: live?.p5 ?? account.lastSessionPercent ?? 0,
            p7: live?.p7 ?? account.lastWeeklyPercent ?? 0,
            ok: live?.isUsable ?? false,
            problem: live?.error ?? (live == nil ? "not checked" : nil),
            resets5h: live?.resets5h
        )
    }

    // MARK: Auto mode

    /// Swaps without being asked, when it is safe to.
    ///
    /// Evaluated on every refresh rather than only when the verdict *changes*.
    /// An earlier version hung this off the notification path, which meant a
    /// swap blocked by a mid-request session was never retried — the verdict was
    /// already SWAP, so nothing fired again once the session went idle. The
    /// interesting moment is usually the unblocking, not the decision.
    func evaluateAutoSwap() {
        guard settings.autoSwap,
              decision.verdict == .swap,
              let target = decision.target,
              target != activeAccountName,
              // Never mid-request: pulling the credential out from under a live
              // turn is the one failure that actually costs work.
              canSwitchNow,
              !isRefreshingToken
        else { return }

        if let last = lastAutoSwapAttempt, now.timeIntervalSince(last) < Self.autoSwapCooldown {
            return
        }
        lastAutoSwapAttempt = now

        let before = activeAccountName
        // Auto mode runs in the background. It may use an existing Keychain
        // grant, but it must never throw a password dialog over another app.
        switchTo(target, allowKeychainPrompt: false)
        if lastSwapError == nil, activeAccountName != before {
            lastAutoSwap = (name: target, at: now)
        }
    }

    /// Human-readable account name for a stored name.
    func label(for name: String) -> String {
        accounts.first { $0.name == name }?.label ?? name
    }

    // MARK: Actions

    func switchTo(
        _ name: String, force: Bool = false, allowKeychainPrompt: Bool = true
    ) {
        guard !isRefreshingToken else {
            lastSwapError = "a token refresh is in flight — try again in a moment"
            return
        }
        do {
            try vault.activate(
                name, force: force, allowKeychainPrompt: allowKeychainPrompt)
            lastSwapError = nil
            refresh()
            Task { await refreshUsage(force: true) }
        } catch {
            lastSwapError = String(describing: error)
        }
    }

    /// Completes a browser sign-in and files the new account.
    ///
    /// Named after its own identity rather than a user-typed label: the token
    /// response carries the email, and a browser sign-in is exactly the case
    /// where the person cannot be sure which account they landed on.
    @discardableResult
    func addAccount(pasted: String, pending: OAuthFlow.Pending) async throws -> StoredAccount {
        let (credentials, identity) = try await OAuthFlow.exchange(
            pasted: pasted, pending: pending, diagnosticsDirectory: vault.root)

        let name = identity?.email ?? "account-\(vault.accounts().count + 1)"
        let account = try vault.adopt(credentials, identity: identity, as: name)
        lastSwapError = nil
        refresh()
        Task { await refreshUsage(force: true) }
        return account
    }

    func captureCurrentAccount(named name: String) {
        guard !isRefreshingToken else {
            lastSwapError = "a token refresh is in flight — try again in a moment"
            return
        }
        do {
            try vault.capture(as: name)
            lastSwapError = nil
            refresh()
        } catch {
            lastSwapError = String(describing: error)
        }
    }

    // MARK: Derived

    /// Signed in to an account the vault has never seen.
    ///
    /// The identity is re-read every few seconds anyway, so a sign-in performed
    /// anywhere — the app's own launcher, a terminal, another tool — surfaces
    /// here without the app having to drive or supervise the login. That is what
    /// makes "add a second account" a real flow rather than an instruction.
    ///
    /// Nil when nothing is saved yet, because then the *first* save is already
    /// the prompt the popover is showing.
    var unsavedAccount: Identity? {
        guard !accounts.isEmpty,
              let identity,
              !accounts.contains(where: { $0.accountUUID == identity.accountUUID })
        else { return nil }
        return identity
    }

    /// The budget. The policy is explicit that the 7-day window is the real
    /// constraint and the 5-hour one is only a throttle, so the week is what the
    /// menu bar and the popover lead with.
    var weekly: Limit? { quota?.weekly }
    var session: Limit? { quota?.session }

    var weeklyPercent: Int? {
        switch weekly?.reading {
        case .live(let p):  return p
        case .rolledOver:   return 0
        case .unknown, nil: return nil
        }
    }

    var sessionPercent: Int? {
        switch session?.reading {
        case .live(let p):  return p
        case .rolledOver:   return 0
        case .unknown, nil: return nil
        }
    }

    /// Colour for the weekly numeral and its meter.
    ///
    /// Derived from the weekly percentage alone. It previously took the policy
    /// verdict's colour first, which meant ROTATE-SOON — a verdict whose only
    /// trigger is the *5-hour* window — turned the WEEKLY figure orange while
    /// the week itself was fine. The verdict has its own accent path in the
    /// verdict block, which is the right and only place for a policy colour.
    var headlineAccent: Color? {
        guard let p = weeklyPercent else { return nil }
        return Theme.accent(for: p, warnAt: Policy.d7Reserve - 20, criticalAt: Policy.d7Reserve)
    }

    /// How long ago Claude Code last refreshed the quota, in words. Always
    /// present, so freshness is a stated fact rather than an opacity the user
    /// has to notice.
    var freshness: String? {
        guard let quota else { return nil }
        let age = quota.age(now: now)
        if age < 90 { return "read just now" }
        return "read \(Format.ago(age)) ago"
    }

    var isStale: Bool { quota?.isStale(now: now) ?? false }

    var canSwitchNow: Bool { !verdict.blocksManualSwitch }
}
