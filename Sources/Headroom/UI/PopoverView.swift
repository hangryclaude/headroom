import SwiftUI

/// The glance surface. It answers one question — *should I keep going, and if
/// not, where do I go next?* — and the weekly numeral is the single focal
/// element, because the week is the budget and the 5-hour window is a throttle.
///
/// Deliberately paints no background of its own: `NSPopover` supplies a native
/// vibrancy material, and covering that is what makes a menu bar app look
/// foreign on the machine.
struct PopoverView: View {
    @Bindable var store: Store
    var onQuit: () -> Void
    var onRefresh: () -> Void
    var onAddAccount: () -> Void
    var onOpenPanel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            headline
            // Shown only when there is something to act on. "All accounts
            // healthy" set in the most prominent face on screen was the loudest
            // element saying the quietest thing.
            if store.decision.verdict.accentPercent != nil {
                rule
                verdictBlock
            }
            rule
            accounts
            rule
            footer
        }
        .padding(.horizontal, Theme.Measure.margin)
        .padding(.top, Theme.Space.s3)
        .padding(.bottom, Theme.Space.s1)
        .frame(width: 420)
    }

    /// Section rules run the full width of the surface, past the margin the
    /// content sits on. Inset rules read as another item in the column, the same
    /// species as the gauges; edge to edge they read as the chassis the readings
    /// are mounted in — and it is how `NSMenu` draws its own separators, which
    /// this view is a guest inside.
    private var rule: some View {
        Divider().padding(.horizontal, -Theme.Measure.margin)
    }

    // MARK: Headline — one instrument face, three readings on it

    /// Labels, figures and gauges as three rows of a fixed grid rather than
    /// three self-contained stat blocks.
    ///
    /// The blocks were the problem the whole header had: each one internally
    /// consistent, none of them aligned to any other, so WEEK sat on one
    /// baseline and SESSION on a different one and the eye read two unrelated
    /// widgets instead of one panel. Rows share a baseline by construction.
    private var headline: some View {
        VStack(alignment: .leading, spacing: 0) {
            gridRow(alignment: .firstTextBaseline) {
                scaleLabel("WEEK USED")
            } column: { limit in
                scaleLabel(limit.kind.label)
            }

            gridRow(alignment: .firstTextBaseline) {
                weekFigure
            } column: { limit in
                CompactLimit(limit: limit)
            }
            // Negative, and measured off the render rather than guessed: a 30pt
            // line box carries ~6pt of ascent above the cap, which showed up as
            // a gap the label and its figure had not asked for. Same below.
            .padding(.top, -5)

            gridRow(alignment: .center) {
                Meter(
                    fraction: Double(store.weeklyPercent ?? 0) / 100,
                    accent: store.headlineAccent,
                    // Graduated at the quarters. What turns a bar into a scale:
                    // you can take "about a third" off it without reading the
                    // numeral above.
                    divisions: 4,
                    pace: store.pace?.elapsed
                )
                .frame(maxWidth: Theme.Measure.heroGauge, alignment: .leading)
                .opacity(store.weeklyPercent == nil ? 0.35 : 1)
            } column: { limit in
                Meter(fraction: Double(limit.reading.percent ?? 0) / 100,
                      accent: limit.accent,
                      divisions: 2)
                .opacity(limit.reading.percent == nil ? 0.35 : 1)
            }
            .padding(.top, -1)

            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s2) {
                Text(weeklySubline)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkTertiary)
                tokenLine
                Spacer(minLength: Theme.Space.s2)
                // Freshness as a stated fact rather than an opacity the user has
                // to notice — and always present, not gated on a threshold,
                // because "how old is this" is always a fair question.
                if let freshness = store.freshness {
                    Text(freshness)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkTertiary)
                        .layoutPriority(1)
                }
            }
            .padding(.top, 5)

            paceLine.padding(.top, 2)
        }
    }

    /// One row of the header grid: the hero cell on its own measure, every
    /// secondary window on an identical one, the slack pushed into the middle so
    /// the last column stays welded to the right margin — which is what the
    /// account gauges below align themselves to.
    private func gridRow<Hero: View, Column: View>(
        alignment: VerticalAlignment,
        @ViewBuilder hero: () -> Hero,
        @ViewBuilder column: @escaping (Limit) -> Column
    ) -> some View {
        HStack(alignment: alignment, spacing: Theme.Measure.gutter) {
            hero().frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(others.enumerated()), id: \.offset) { _, limit in
                column(limit).frame(width: Theme.Measure.column, alignment: .leading)
            }
        }
    }

    private func scaleLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.scaleLabel)
            .tracking(Theme.scaleTracking)
            .foregroundStyle(Theme.inkTertiary)
            // Scoped weekly windows are named after whatever model Anthropic
            // ships. In a fixed column an unexpectedly long one would wrap and
            // take the shared baseline down with it; a truncated label is a much
            // cheaper failure than a broken grid.
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// The hero, at 30pt rather than 48.
    ///
    /// Set as a single text run so the "%" cannot detach: two `Text`s aligned by
    /// `.firstTextBaseline` were nominally on one baseline and still read as a
    /// glyph floating loose under the numeral, because a 48/18 size gap is too
    /// wide for the eye to accept as one word. Concatenation typesets both in
    /// one line box, and 30/15 is a ratio the pair survives.
    private var weekFigure: some View {
        let figure = Text(store.weeklyPercent.map { "\($0)" } ?? "—")
            .font(Theme.numeral(36))
            .tracking(Theme.numeralTracking(36))
            .foregroundStyle(store.headlineAccent ?? Theme.ink)

        // No unit on a reading that does not exist: "—%" is not a measurement.
        let unit = store.weeklyPercent == nil ? Text("") :
            Text("%").font(Theme.unit(18)).foregroundStyle(Theme.inkTertiary)

        // Deliberately NOT dimmed when stale.
        //
        // Staleness is the resting state, not an exception: the usage cache only
        // refreshes while Claude Code is running, so a reading minutes old is
        // normal. Fading the hero for it put the most important figure on the
        // surface *below* the secondaries in contrast, since those never dim --
        // an inverted ink ramp for the majority of the app's life. The freshness
        // line already says "read 57m ago" in words a few points below, so the
        // fade was double-encoding the one thing that was already explicit.
        // (Same mistake, same fix as the menu bar icon.)
        return (figure + unit)
            .animation(Theme.stateChange, value: store.weeklyPercent)
    }

    /// The pacing read, which is why the week leads. A percentage alone cannot
    /// say whether 16% is comfortable or alarming; against the elapsed fraction
    /// of the window it can.
    @ViewBuilder
    private var paceLine: some View {
        if let pace = store.pace, let verdict = store.paceVerdict {
            Text(verdict)
                .font(Theme.caption)
                .foregroundStyle(pace.severityPercent.flatMap { Theme.accent(for: $0) }
                                 ?? Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var weeklySubline: String {
        if store.quotaError != nil { return "run Claude Code once" }
        guard let weekly = store.weekly else { return "no weekly window" }
        if let remaining = weekly.timeRemaining(now: store.now) {
            return "refills in \(Format.longCountdown(remaining))"
        }
        return "window reset"
    }

    // MARK: Secondary windows and tokens

    private var others: [Limit] {
        (store.quota?.limits ?? []).filter { $0.kind != .weeklyAll }
    }

    @ViewBuilder
    private var tokenLine: some View {
        let day = store.tokens24h
        if day.total > 0 {
            let priced = Pricing.cost(store.tokensByModel24h)
            HStack(spacing: Theme.Space.s1) {
                Text("·").foregroundStyle(Theme.inkTertiary)
                Text(Format.tokens(day.total))
                Text("24h").foregroundStyle(Theme.inkTertiary)
                if priced.total > 0 {
                    Text("·").foregroundStyle(Theme.inkTertiary)
                    // Labelled, because on a subscription this is emphatically
                    // not a bill -- it is what these tokens would have cost at
                    // API rates. An unlabelled dollar figure reads as money owed.
                    Text("\(Pricing.format(priced.total)) at API rates")
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            .font(Theme.value)
            .foregroundStyle(Theme.inkSecondary)
        }
    }

    // MARK: Verdict — plain English, reasoning underneath

    private var verdictBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(store.decision.verdict.headline)
                .font(Theme.body.weight(.medium))
                .foregroundStyle(
                    store.decision.verdict.accentPercent
                        .flatMap { Theme.accent(for: $0) } ?? Theme.ink)
            Text(store.decision.why)
                .font(Theme.caption)
                .foregroundStyle(Theme.inkTertiary)
                .lineLimit(2)
                .help(store.decision.why)
        }
    }

    // MARK: Accounts

    private var accounts: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s1) {
            if store.accounts.isEmpty {
                Text(store.identity?.email ?? "not signed in")
                    .font(Theme.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("save this account to switch between logins")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkTertiary)
            } else {
                ForEach(store.accounts) { account in
                    AccountRow(
                        account: account,
                        isActive: account.name == store.activeAccountName,
                        isTarget: account.name == store.decision.target
                            && account.name != store.activeAccountName,
                        usage: store.usage[account.name],
                        // The active account's reading comes from the local
                        // quota rather than the usage endpoint — Claude Code has
                        // already fetched it, so spending a request would be
                        // waste, but the row still has to show it.
                        liveWeekly: account.name == store.activeAccountName
                            ? store.weeklyPercent : nil,
                        enabled: store.canSwitchNow,
                        action: { store.switchTo(account.name) }
                    )
                }
            }

            newAccountPrompt

            if let error = store.lastSwapError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.accent(for: 100) ?? Theme.inkSecondary)
                    .padding(.top, Theme.Space.s1)
            }

            autoMode

            Divider().padding(.vertical, Theme.Space.s1)
            modelRow
        }
    }

    /// The other half of "sign in to another account": the app noticed you did.
    ///
    /// Appears the moment `~/.claude.json` names an account the vault has never
    /// seen — however you signed in. Saving from here is the step that makes the
    /// new login switchable instead of merely current.
    @ViewBuilder
    private var newAccountPrompt: some View {
        if let unsaved = store.unsavedAccount {
            HStack(spacing: Theme.Space.s2) {
                Image(systemName: "person.badge.plus")
                    .foregroundStyle(Theme.accent(for: 75) ?? Theme.ink)
                VStack(alignment: .leading, spacing: 0) {
                    Text("New account signed in")
                        .font(Theme.body)
                    Text(unsaved.email)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Theme.Space.s2)
                Button("Save") { onAddAccount() }
                    .controlSize(.small)
            }
            .padding(.top, Theme.Space.s2)
        }
    }

    /// Auto mode, as a switch rather than a buried menu item — it changes which
    /// account you are signed into, so it should be visible and one click away.
    ///
    /// Only shown once there is more than one account: a toggle that cannot
    /// possibly do anything is noise.
    @ViewBuilder
    private var autoMode: some View {
        if store.accounts.count > 1 {
            Divider().padding(.vertical, Theme.Space.s1)

            Toggle(isOn: Binding(
                get: { store.settings.autoSwap },
                set: { store.settings.autoSwap = $0 }
            )) {
                Text("Auto-swap")
                    .font(Theme.body)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            if let explanation = autoModeExplanation {
                Text(explanation)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1)
            }
        } else if !store.canSwitchNow && store.accounts.count > 1 {
            Text("switching held — a session is mid-request")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkTertiary)
        }
    }

    /// The other lever on quota.
    ///
    /// Swapping accounts buys a fresh window; dropping a tier makes the current
    /// one last. Both belong on the surface that shows you the window running
    /// out, and this one is cheaper — it costs nothing and needs no second
    /// subscription.
    ///
    /// A segmented picker rather than a menu because there are three options and
    /// the current one has to be readable without a click. It takes no accent
    /// while healthy: selection here is a preference, not a warning.
    @ViewBuilder
    private var modelRow: some View {
        HStack(spacing: Theme.Space.s2) {
            Text("Model")
                .font(Theme.body)

            Picker("Model", selection: Binding(
                get: { store.model },
                set: { store.setModel($0) }
            )) {
                ForEach(ClaudeModel.allCases, id: \.self) { model in
                    Text(model.label).tag(Optional(model))
                }
                // Claude Code accepts values this picker does not offer
                // (`opusplan`, `sonnet[1m]`). Showing the real one keeps the
                // control honest instead of reading as though nothing is set.
                if store.model == nil {
                    Text(store.modelRaw ?? "—").tag(ClaudeModel?.none)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .fixedSize()
        }

        Text("applies to new sessions — open ones keep their model")
            .font(Theme.caption)
            .foregroundStyle(Theme.inkTertiary)
            .lineLimit(1)
    }

    /// Says what the switch is actually doing right now, not what it does in
    /// general — including the case where it is on but currently held.
    private var autoModeExplanation: String? {
        // Off needs no gloss — the switch says it.
        guard store.settings.autoSwap else { return nil }
        if let last = store.lastAutoSwap {
            return "switched to \(store.label(for: last.name)) \(Format.ago(store.now.timeIntervalSince(last.at))) ago"
        }
        if !store.canSwitchNow {
            return "on — held while a session is mid-request"
        }
        return "on — moves you when an account runs out, never mid-request"
    }

    // MARK: Footer — native controls rather than hand-rolled text buttons

    private var footer: some View {
        HStack(spacing: Theme.Space.s1) {
            control("Details", "list.bullet.rectangle", onOpenPanel)
            control("Add Account", "person.badge.plus", onAddAccount)
            Spacer(minLength: Theme.Space.s2)
            control("Refresh", "arrow.clockwise", onRefresh)
            control("Quit", "power", onQuit)
        }
        .controlSize(.small)
        .buttonStyle(.accessoryBar)
        .imageScale(.small)
        .padding(.horizontal, -Theme.Measure.accessoryInset)
    }

    /// Every footer control is a glyph and a word, in that order.
    ///
    /// Two text buttons on the left and two bare glyphs on the right implied a
    /// distinction the actions do not have — a glyph-only control reads as a
    /// mode or a state, not as a verb. One species, and the left/right split is
    /// then free to carry the only real grouping: about the data, about the app.
    private func control(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(Theme.caption)
        }
        .help(title)
    }
}

/// One saved account.
///
/// With three subscriptions this list is the main event, so each row has to
/// answer three things at a glance: which one am I on, how much has each got
/// left, and where would I go next. Anything beyond that is chrome.
private struct AccountRow: View {
    let account: StoredAccount
    let isActive: Bool
    let isTarget: Bool
    let usage: AccountUsage?
    let liveWeekly: Int?
    let enabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        // The marker sits *outside* the button on purpose. The active row is a
        // disabled button — you cannot switch to the account you are on — and
        // AppKit dims disabled content wholesale, so the one indicator that says
        // "this is the live account" was being greyed out precisely on the row
        // it had to be loudest on. In the gutter it stays at full strength, and
        // the hover chip has a margin to sit in.
        HStack(spacing: Theme.Space.s2) {
            RoundedRectangle(cornerRadius: 1)
                .fill(isActive ? Theme.ink : Theme.track)
                .frame(width: 3, height: 16)

            row
        }
    }

    private var row: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s2) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(account.label)
                        .font(Theme.body)
                        .foregroundStyle(isActive ? Theme.ink : Theme.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let sub = subtitle {
                        Text(sub)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.inkTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: Theme.Space.s2)

                // Figure then gauge, both on fixed measures ending at the right
                // margin — so every account's gauge starts and ends on the same
                // verticals as the last column of the header above. A gauge that
                // floats to wherever its row's text ran out is a gauge you
                // cannot compare against the one beneath it.
                Text(value)
                    .font(Theme.value)
                    .foregroundStyle(valueColour)
                    .frame(width: Theme.Measure.rowValue, alignment: .trailing)
                Meter(fraction: Double(weeklyPercent ?? 0) / 100,
                      accent: meterAccent,
                      width: Theme.Measure.column,
                      height: Theme.meterHeightRow,
                      divisions: 2)
                    .opacity(weeklyPercent == nil ? 0.35 : 1)
            }
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: Theme.rowRadius)
                    .fill(hovering && enabled && !isActive ? Theme.hover : .clear)
                    // Bleeds outward so the chip has padding without pushing the
                    // row off the surface's single left margin.
                    .padding(.horizontal, -Theme.Space.s1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isActive || !enabled)
        .onHover { hovering = $0 }
        .animation(Theme.stateChange, value: hovering)
        .help(helpText)
    }

    /// Live if we have it, remembered otherwise — and the two are never conflated.
    private var weeklyPercent: Int? { liveWeekly ?? usage?.p7 ?? account.lastWeeklyPercent }

    /// True when the figure came from the last swap-out rather than the server.
    private var isRemembered: Bool {
        liveWeekly == nil && usage?.p7 == nil && account.lastWeeklyPercent != nil
    }

    private var subtitle: String? {
        if isActive { return "signed in" }
        if let error = usage?.error { return error }
        if isTarget { return "most headroom" }
        return nil
    }

    private var value: String {
        guard let p7 = weeklyPercent else { return usage?.error == nil ? "—" : "" }
        // "~" marks a remembered reading. A figure captured days ago should not
        // be able to pass as a live one.
        return isRemembered ? "~\(p7)%" : "\(p7)%"
    }

    /// A remembered figure never raises an alarm — it is not current enough to
    /// justify one, and a stale warning is worse than none.
    private var meterAccent: Color? {
        guard !isRemembered, let p7 = weeklyPercent else { return nil }
        return Theme.accent(for: p7, warnAt: Policy.d7Reserve - 20, criticalAt: Policy.d7Reserve)
    }

    private var valueColour: Color {
        if isRemembered { return Theme.inkTertiary }
        return meterAccent ?? (isActive ? Theme.ink : Theme.inkSecondary)
    }

    private var helpText: String {
        var parts: [String] = []
        if isActive { parts.append("currently signed in") }
        else if !enabled { parts.append("a session is mid-request") }
        else { parts.append("switch to \(account.label)") }

        if let fetchedAt = usage?.fetchedAt {
            parts.append("usage \(Format.ago(Date().timeIntervalSince(fetchedAt))) old")
        } else if isRemembered, let seen = account.usageFetchedAt {
            parts.append("remembered from \(Format.ago(Date().timeIntervalSince(seen))) ago")
        }
        return parts.joined(separator: " · ")
    }
}

enum Format {
    static func countdown(_ t: TimeInterval) -> String {
        let total = max(0, Int(t))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d", h, m) }
        if m >= 5 { return "\(m)m" }
        return "\(m)m \(s)s"
    }

    /// Weekly windows are measured in days, where an h:mm countdown is noise.
    static func longCountdown(_ t: TimeInterval) -> String {
        let total = max(0, Int(t))
        let d = total / 86400, h = (total % 86400) / 3600
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        return countdown(t)
    }

    static func ago(_ t: TimeInterval) -> String {
        let total = max(0, Int(t))
        if total < 90 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        if total < 86400 { return "\(total / 3600)h" }
        return "\(total / 86400)d"
    }

    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB", Double(n) / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.0fM", Double(n) / 1_000_000)
        case 1_000...:         return String(format: "%.0fk", Double(n) / 1_000)
        default:               return "\(n)"
        }
    }
}
