import SwiftUI

/// The Devin block: a status line, then the sessions worth looking at.
///
/// Sits on the same measures as the account rows above it — value column, gauge
/// column, right margin — so it reads as another instrument on the same chassis
/// rather than a widget bolted underneath.
///
/// The block is absent, not empty, when Devin is unconfigured. `Store` returns a
/// nil summary in that case and the caller never builds this view.
struct DevinSection: View {
    let summary: DevinUsage.Summary
    let sessions: [DevinSession]
    let error: String?
    /// Nil when no allowance is configured, which is the normal state — no
    /// endpoint reports a self-serve plan's ACU limit.
    let allowance: Double?
    /// False until the first fetch settles. "no sessions yet" before then would
    /// state something not yet known.
    let hasLoaded: Bool
    var onOpen: (URL) -> Void

    /// Enough to see what is live without turning the popover into a list.
    /// Anything past this is a job for the web app, which the footer links to.
    private static let visibleRows = 3

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s1) {
            header

            if let error {
                // Same contract as the account rows: a failed fetch states its
                // reason. It must never fall through to the zero counts below,
                // which would read as "nothing running" rather than "unknown".
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.accent(for: 100) ?? Theme.inkSecondary)
            } else if !hasLoaded {
                Text("checking…")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkTertiary)
            } else if summary.isEmpty {
                Text("no sessions yet")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkTertiary)
            } else {
                ForEach(interesting, id: \.id) { session in
                    row(session)
                }
                if interesting.count < sessions.count {
                    Text("+\(sessions.count - interesting.count) more")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
        }
    }

    // MARK: Header — counts on the left, ACUs on the same verticals as the gauges

    private var header: some View {
        HStack(spacing: Theme.Space.s2) {
            Text("DEVIN")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
                .tracking(0.6)

            Text(counts)
                .font(Theme.caption)
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)

            Spacer(minLength: Theme.Space.s2)

            Text(isKnown ? acuText : "—")
                .font(Theme.value)
                .foregroundStyle(acuColour)
                .frame(width: Theme.Measure.rowValue, alignment: .trailing)

            // The gauge only appears once there is a denominator to divide by.
            // A full-width bar with no allowance behind it would be decoration
            // claiming to be a measurement.
            if let percent = summary.percent {
                Meter(fraction: min(percent / 100, 1),
                      accent: Theme.accent(for: Int(percent)),
                      width: Theme.Measure.column,
                      height: Theme.meterHeightRow,
                      divisions: 2)
                    // Dimmed until the number behind it is known, the same way
                    // the header gauges treat a missing reading. A crisp bar at
                    // zero is a measurement claiming plenty of room.
                    .opacity(isKnown ? 1 : 0.35)
            } else {
                Text("no allowance set")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.inkTertiary)
                    .frame(width: Theme.Measure.column, alignment: .trailing)
            }
        }
    }

    private func row(_ session: DevinSession) -> some View {
        Button {
            if let url = session.url { onOpen(url) }
        } label: {
            HStack(spacing: Theme.Space.s2) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(marker(session.status))
                    .frame(width: 3, height: 12)

                Text(session.displayTitle)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: Theme.Space.s2)

                // status_detail is more specific than status when present:
                // "waiting_for_user" is actionable, "suspended" is not.
                // Fixed measure for the same reason as the figures beside it: a
                // status that ends wherever its word ran out gives the eye three
                // ragged right edges to track instead of one.
                Text(detail(session))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 62, alignment: .trailing)

                Text(String(format: "%.1f", session.acusConsumed))
                    .font(Theme.value)
                    .foregroundStyle(Theme.inkTertiary)
                    .frame(width: Theme.Measure.rowValue, alignment: .trailing)

                // Deliberately blank, and deliberately still occupying the gauge
                // column. Letting the per-session figures run to the right margin
                // put them on a different vertical from the section's own total
                // directly above — the exact "each block internally consistent,
                // none aligned to any other" failure the header was rebuilt to fix.
                Color.clear.frame(width: Theme.Measure.column, height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.url == nil)
    }

    // MARK: Pieces

    /// Live work first, then whatever is parked. A finished session is history
    /// and does not earn a row while anything is still moving.
    private var interesting: [DevinSession] {
        let ranked = sessions.sorted { a, b in
            let rank = { (s: DevinSession) -> Int in
                if s.status.isActive { return 0 }
                if s.status.isAsleep { return 1 }
                if s.status.isFailed { return 2 }
                return 3
            }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.updatedAt > b.updatedAt
        }
        return Array(ranked.prefix(Self.visibleRows))
    }

    /// `status_detail` is the more useful of the two labels but it is snake_case
    /// and can run long; "waiting_for_user" alone was costing the title sixteen
    /// points of a column the title needs more.
    private func detail(_ session: DevinSession) -> String {
        guard let raw = session.statusDetail, !raw.isEmpty else { return session.status.label }
        switch raw {
        case "waiting_for_user": return "waiting"
        case "finished":         return "done"
        default:                 return raw.replacingOccurrences(of: "_", with: " ")
        }
    }

    private var counts: String {
        // Before the first fetch settles there is nothing true to say. "idle"
        // would be a claim about sessions that have not been looked at yet.
        guard isKnown else { return "—" }
        var parts: [String] = []
        if summary.active > 0 { parts.append("\(summary.active) running") }
        if summary.asleep > 0 { parts.append("\(summary.asleep) asleep") }
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        return parts.isEmpty ? "idle" : parts.joined(separator: " · ")
    }

    /// Whether the numbers on this row describe a fetch that actually happened.
    private var isKnown: Bool { hasLoaded && error == nil }

    private var acuText: String {
        // Whole ACUs past ten: the decimal is noise at that size, and the column
        // is shared with the account percentages which are integers.
        summary.acus >= 10
            ? "\(Int(summary.acus.rounded()))"
            : String(format: "%.1f", summary.acus)
    }

    private var acuColour: Color {
        guard let percent = summary.percent else { return Theme.inkSecondary }
        return Theme.accent(for: Int(percent)) ?? Theme.ink
    }

    private func marker(_ status: DevinSession.Status) -> Color {
        if status.isFailed { return Theme.accent(for: 100) ?? Theme.inkSecondary }
        if status.isActive { return Theme.ink }
        return Theme.track
    }
}
