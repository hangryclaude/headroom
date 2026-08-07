import SwiftUI

/// A capsule fill bar with an optional pace notch.
///
/// Drawn as a single `Canvas` pass rather than stacked SwiftUI shapes. Two
/// reasons, both load-bearing:
///
/// - **The notch has to be a hole, not a covering.** Filling a rectangle with
///   the window background paints an opaque colour that only *looks* like a gap
///   over one particular backdrop — over a vibrancy material it reads as a
///   smudge. `.destinationOut` removes pixels, so the notch is legible whether
///   it lands on the fill or the track, which in turn frees its colour to carry
///   meaning instead of being spent on legibility.
/// - Compositing layered shapes with blend modes inside a status item is what
///   made CodexBar's menu bar icon vanish on macOS 26 (their issue #805). One
///   Canvas keeps it to a single Core Graphics context.
struct Meter: View {
    let fraction: Double
    /// Nil while healthy, which is the normal case.
    let accent: Color?
    var width: CGFloat? = nil
    var height: CGFloat = Theme.meterHeight
    /// How many equal parts to score the scale into — 4 draws quarter marks.
    /// 0 leaves the bar plain, which is right for anything list-sized.
    var divisions: Int = 0
    /// Where consumption *should* be, as a fraction of the window elapsed.
    var pace: Double? = nil

    var body: some View {
        Canvas { ctx, size in
            let h = size.height
            // Near-square rather than a capsule. Round ends are the giveaway of
            // a web progress bar, and at 4pt they also made the empty track
            // indistinguishable from the section rules elsewhere on the surface.
            let bar = Path(roundedRect: CGRect(origin: .zero, size: size),
                           cornerRadius: Theme.meterRadius)

            ctx.fill(bar, with: .color(Theme.track))

            // Clipped to the bar and drawn as a straight-edged rect, so the
            // progress edge is a hard vertical line rather than a curved cap
            // that reads as more progress than there is.
            let filled = max(0, min(1, fraction)) * size.width
            if filled > 0 {
                var layer = ctx
                layer.clip(to: bar)
                layer.fill(
                    Path(CGRect(x: 0, y: 0, width: filled, height: h)),
                    with: .color(accent ?? Theme.meterFillHealthy)
                )
            }

            // Scale marks, punched out for the same reason the pace notch is:
            // one treatment that reads over the fill and over the empty track
            // alike. They are what let you take a rough figure off the gauge
            // without reading the numeral above it.
            //
            // Notched into the bottom edge, not cut clean through. Full-height
            // gaps chopped the bar into four separate blocks — a segmented
            // battery indicator, four things where there is one — while a
            // graduation that stops short leaves the bar continuous and still
            // marks the quarters.
            //
            // Two depths, major and minor, because a rule with one depth of mark
            // is a dotted line and a rule with two is a scale. Callers pick
            // `divisions` so the *pitch* comes out roughly equal across gauges of
            // different widths: at 4 on the 180pt week bar and 2 on the 86pt
            // secondaries the marks land ~22pt apart on both, and the header
            // reads as one instrument face rather than three unrelated bars.
            if divisions > 1 {
                let major = max(2, (h * 0.5).rounded())
                let minor = max(1, (h * 0.25).rounded())
                let steps = divisions * 2
                ctx.blendMode = .destinationOut
                for i in 1..<steps {
                    let x = (size.width * Double(i) / Double(steps)).rounded()
                    let depth = i.isMultiple(of: 2) ? major : minor
                    ctx.fill(Path(CGRect(x: x - 0.5, y: h - depth, width: 1, height: depth)),
                             with: .color(.black))
                }
                ctx.blendMode = .normal
            }

            if let pace {
                // Punch, then draw the marker back in. Legible on both sides,
                // so its colour is free to say ahead-or-behind.
                let x = max(0, min(1, pace)) * size.width
                let gap = Path(CGRect(x: x - 1.5, y: 0, width: 3, height: h))
                ctx.blendMode = .destinationOut
                ctx.fill(gap, with: .color(.black))
                ctx.blendMode = .normal
                ctx.fill(
                    Path(CGRect(x: x - 0.5, y: 0, width: 1, height: h)),
                    with: .color(Theme.inkSecondary)
                )
            }
        }
        .frame(width: width, height: height)
        .animation(Theme.meterFill, value: fraction)
    }
}

extension Limit {
    /// The accent this window earns under the configured thresholds — nil while
    /// healthy. Lives here rather than in three call sites because the figure,
    /// its gauge and its tooltip must never disagree about severity.
    var accent: Color? {
        guard let p = reading.percent else { return nil }
        if case .session = kind {
            return Theme.accent(for: p, warnAt: Policy.h5Soft, criticalAt: Policy.h5Hard)
        }
        return Theme.accent(for: p, warnAt: Policy.d7Reserve - 20, criticalAt: Policy.d7Reserve)
    }

    /// What the figure reads. A rolled-over window reports "reset", not "0%":
    /// nothing has been *measured* there — the cached percentage describes a
    /// window that no longer exists. The policy still ranks it as zero, but
    /// printing a zero would present an inference as a reading.
    var valueText: String {
        switch reading {
        case .live(let p):  return "\(p)%"
        case .rolledOver:   return "reset"
        case .unknown:      return "—"
        }
    }
}

/// One secondary window's *figure*, and nothing else.
///
/// The label and the gauge that belong to it are laid out by the header grid
/// alongside the week's, because the three readings share three verticals and a
/// baseline apiece. A self-contained stat cell cannot participate in that.
struct CompactLimit: View {
    let limit: Limit

    var body: some View {
        Text(limit.valueText)
            // Half the hero, so the two land on one baseline as a matched pair
            // rather than a headline with a footnote stuck beside it.
            .font(Theme.reading)
            .foregroundStyle(limit.accent ?? Theme.inkSecondary)
            .lineLimit(1)
            .help(helpText)
    }

    private var helpText: String {
        switch limit.reading {
        case .rolledOver:
            return "window reset — nothing measured since"
        case .unknown:
            return "no reading yet"
        case .live:
            if let resets = limit.resetsAt {
                return "resets \(Forecaster.when(resets))"
            }
            return limit.kind.label.capitalized
        }
    }
}

/// A secondary window with room to breathe: label left, value right, meter
/// beneath. Used in the panel.
struct LimitRow: View {
    let limit: Limit

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s1) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.kind.label.capitalized)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
                Spacer(minLength: Theme.Space.s4)
                Text(limit.valueText)
                    .font(Theme.value)
                    .foregroundStyle(limit.accent ?? Theme.inkSecondary)
            }
            Meter(fraction: Double(limit.reading.percent ?? 0) / 100,
                  accent: limit.accent,
                  divisions: 4)
        }
    }
}
