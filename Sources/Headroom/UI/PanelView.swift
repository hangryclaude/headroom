import SwiftUI

/// The detail surface. Everything the popover deliberately refuses to carry:
/// the pace argument in full, where the tokens went, and what they cost.
///
/// It exists because the popover answers one question and a forecast is a
/// different question. Cramming both into 300pt would have wrecked the thing
/// that makes the popover readable.
struct PanelView: View {
    @Bindable var store: Store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                week
                session
                spend
                breakdown
            }
            .padding(Theme.Space.s7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

    }

    // MARK: Week

    @ViewBuilder
    private var week: some View {
        Section("THE WEEK") {
            if let pace = store.pace, let verdict = store.paceVerdict {
                PaceChart(pace: pace)
                    .frame(height: 64)
                    .padding(.bottom, Theme.Space.s2)

                Text(verdict)
                    .font(Theme.body)
                    .foregroundStyle(pace.severityPercent.flatMap { Theme.accent(for: $0) }
                                     ?? Theme.inkSecondary)

                Grid(alignment: .leading, horizontalSpacing: Theme.Space.s6,
                     verticalSpacing: Theme.Space.s2) {
                    Row("spent", "\(Int(pace.spent * 100))% of the weekly budget")
                    Row("elapsed", "\(Int(pace.elapsed * 100))% of the window")
                    Row("pace", String(format: "%.2f×", pace.ratio))
                    if let exhaustsAt = pace.exhaustsAt, pace.willExhaust {
                        Row("runs out", Forecaster.when(exhaustsAt, now: store.now))
                    }
                    Row("refills", Forecaster.when(pace.resetsAt, now: store.now))
                }
                .padding(.top, Theme.Space.s2)
            } else {
                Text("no weekly window yet — run Claude Code once")
                    .font(Theme.body)
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
    }

    // MARK: Session

    @ViewBuilder
    private var session: some View {
        Section("THE 5-HOUR THROTTLE") {
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.s6,
                 verticalSpacing: Theme.Space.s2) {
                Row("used", store.sessionPercent.map { "\($0)%" } ?? "—")
                if let resets = store.session?.timeRemaining(now: store.now) {
                    Row("resets in", Format.countdown(resets))
                }
                if let wall = store.sessionWall {
                    Row("hits the wall", Forecaster.when(wall, now: store.now))
                } else if store.sessionPercent != nil {
                    Row("hits the wall", "not before it resets")
                }
                if store.burnPerMinute > 0 {
                    Row("burn", "\(Format.tokens(Int(store.burnPerMinute))) tok/min")
                }
            }
        }
    }

    // MARK: Spend

    @ViewBuilder
    private var spend: some View {
        let priced = Pricing.cost(store.tokensByModel24h)
        Section("COST AT API RATES · LAST 24H") {
            if store.tokensByModel24h.isEmpty {
                Text("measuring — no requests indexed yet")
                    .font(Theme.body)
                    .foregroundStyle(Theme.inkTertiary)
            } else {
                Text(Pricing.format(priced.total))
                    .font(Theme.numeral(40))
                    .tracking(Theme.numeralTracking(40))
                    .foregroundStyle(Theme.ink)

                // Said plainly, because a bare dollar figure on a subscription
                // reads as a bill. It is a measure of how much work went
                // through, not money owed.
                Text("what these tokens would cost on the API — not what your subscription charges")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                // Named rather than folded into the total: a silently partial
                // number is worse than a smaller one that says what it omits.
                if !priced.unpriced.isEmpty {
                    Text("excludes \(priced.unpriced.joined(separator: ", ")) — no rate on file")
                        .font(Theme.body)
                        .foregroundStyle(Theme.inkTertiary)
                }

                Grid(alignment: .leading, horizontalSpacing: Theme.Space.s6,
                     verticalSpacing: Theme.Space.s2) {
                    ForEach(store.tokensByModel24h.sorted(by: { $0.value.total > $1.value.total }),
                            id: \.key) { model, usage in
                        GridRow {
                            Text(model)
                                .font(Theme.value)
                                .foregroundStyle(Theme.inkSecondary)
                            Text(Format.tokens(usage.total))
                                .font(Theme.value)
                                .foregroundStyle(Theme.inkSecondary)
                            Text(Pricing.cost(usage, model: model).map(Pricing.format) ?? "—")
                                .font(Theme.value)
                                .foregroundStyle(Theme.ink)
                        }
                    }
                }
                .padding(.top, Theme.Space.s3)
            }
        }
    }

    // MARK: Token breakdown

    @ViewBuilder
    private var breakdown: some View {
        let day = store.tokens24h
        if day.total > 0 {
            Section("WHERE THE TOKENS WENT · 24H") {
                // Cache reads dominate this list by an order of magnitude on a
                // real workload, which is the point of showing it: the headline
                // token count is mostly re-reading context, not new work.
                TokenBar(label: "cache read", value: day.cacheRead, total: day.total)
                TokenBar(label: "cache write 5m", value: day.cacheWrite5m, total: day.total)
                TokenBar(label: "cache write 1h", value: day.cacheWrite1h, total: day.total)
                TokenBar(label: "output", value: day.output, total: day.total)
                TokenBar(label: "input", value: day.input, total: day.total)
            }
        }
    }
}

// MARK: - Pieces

/// Spend plotted against the straight line it should be following.
private struct PaceChart: View {
    let pace: Pace

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                // The budget line: spend proportional to time elapsed.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h))
                    p.addLine(to: CGPoint(x: w, y: 0))
                }
                .stroke(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

                // Actual spend to date, as a straight run from the origin.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h))
                    p.addLine(to: CGPoint(x: w * pace.elapsed, y: h - h * pace.spent))
                }
                .stroke(pace.severityPercent.flatMap { Theme.accent(for: $0) } ?? Theme.ink,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1)
                    .offset(x: w * pace.elapsed)
            }
        }
        .animation(Theme.meterFill, value: pace.spent)
    }
}

private struct TokenBar: View {
    let label: String
    let value: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s1) {
            HStack {
                Text(label)
                    .font(Theme.value)
                    .foregroundStyle(Theme.inkSecondary)
                Spacer()
                Text(Format.tokens(value))
                    .font(Theme.value)
                    .foregroundStyle(Theme.inkTertiary)
            }
            Meter(fraction: total > 0 ? Double(value) / Double(total) : 0,
                  accent: nil, width: nil)
        }
        .padding(.bottom, Theme.Space.s2)
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            Text(title)
                .font(Theme.label)
                .foregroundStyle(Theme.inkTertiary)
            content
        }
    }
}

private struct Row: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(label)
                .font(Theme.body)
                .foregroundStyle(Theme.inkTertiary)
            Text(value)
                .font(Theme.value)
                .foregroundStyle(Theme.ink)
                .gridCellColumns(2)
        }
    }
}
