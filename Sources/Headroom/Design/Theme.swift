import AppKit
import SwiftUI

/// The design system.
///
/// Two rules, and everything else follows from them.
///
/// **1. Sit in the system's materials, don't paint over them.** A menu bar
/// popover already renders a vibrancy material behind its content; an opaque
/// custom background covers that up and the app immediately stops looking like
/// it belongs on the machine. So there is no surface colour here — the material
/// shows through — and every foreground is a semantic system colour that adapts
/// to appearance, accent, increased contrast, and reduce-transparency for free.
///
/// **2. A healthy reading has no colour.** Every competitor ships a
/// green/amber/red status dot, so the interface is shouting even when nothing is
/// wrong and you stop reading it. Here the accent is spent only on the meter
/// that is actually in trouble. `accent(for:)` returning nil expresses that in
/// the type system: there is deliberately no success colour to reach for.
enum Theme {

    // MARK: Colour — semantic, so appearance and accessibility settings just work

    static let ink = Color.primary
    static let inkSecondary = Color.primary.opacity(0.72)
    static let inkTertiary = Color.primary.opacity(0.5)

    /// Unfilled meter track. Deliberately a step heavier than `hairline`: the
    /// two resolved to the same pixel value at first, so the empty part of the
    /// hero gauge was indistinguishable from a section rule.
    static let track = Color.primary.opacity(0.16)
    static let hairline = Color(nsColor: .separatorColor)

    /// A healthy meter fill.
    ///
    /// Not `Color.primary`. Severity has to read as an *increase* in salience,
    /// and against a white background `Color.primary` measures ~15.7:1 while the
    /// warning orange measures ~2.3:1 — so a full-contrast healthy bar made
    /// "in trouble" the quieter state, exactly inverting the hierarchy the whole
    /// design rests on. Held down here, the accent is a step up.
    static let meterFillHealthy = Color.primary.opacity(0.55)

    /// Row hover. `.selection` follows the user's accent colour.
    static let hover = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)

    private static let amber = Color(nsColor: .systemOrange)
    private static let red = Color(nsColor: .systemRed)

    /// Nil while healthy — the caller falls back to plain ink.
    ///
    /// Above `warnAt` the colour ramps orange → red so severity is legible from
    /// hue alone, without introducing a second accent family.
    static func accent(for percent: Int, warnAt: Int = 70, criticalAt: Int = 92) -> Color? {
        guard percent >= warnAt else { return nil }
        let span = max(criticalAt - warnAt, 1)
        let t = min(Double(percent - warnAt) / Double(span), 1)
        return amber.blended(with: red, by: t)
    }

    // MARK: Type — the system face throughout
    //
    // SF is the native voice; a monospaced face for prose reads as terminal
    // output, which is what made this feel like a tool rather than an app.
    // Tabular figures are applied to *numbers only*, where they stop digits
    // jittering as they tick.

    /// The focal numeral. Regular rather than bold — heavy weights at display
    /// sizes read cheap — but not the hairline weight this started at, which
    /// disappeared against a translucent material.
    /// Proportional, not tabular.
    ///
    /// Nothing is column-aligned to the hero numeral — it is a single
    /// left-anchored value — and tabular figures give "1" the same advance as
    /// "0", which leaves the ink visibly inboard of the margin every time the
    /// reading starts with a 1. Tabular stays on `value`, where columns do line
    /// up, and on the menu bar title, where digits tick.
    static func numeral(_ size: CGFloat = 56) -> Font {
        .system(size: size, weight: .regular)
    }

    /// Display type needs negative tracking or it falls apart; -0.02em resolved
    /// against the point size.
    static func numeralTracking(_ size: CGFloat = 56) -> CGFloat { size * -0.02 }

    /// Figures in rows and meters.
    ///
    /// Everything here runs a weight heavier than a plain system default: this
    /// content sits on a translucent vibrancy material, where regular weight at
    /// 12pt reads washed out against whatever is behind the popover.
    static let value = Font.system(size: 12, weight: .medium).monospacedDigit()
    static let valueEmphasis = Font.system(size: 12, weight: .semibold).monospacedDigit()

    /// The secondary windows in the header cluster — session and any scoped
    /// weekly. Exactly half the hero's size so the two sit on a shared baseline
    /// as one instrument face rather than a headline with footnotes beside it.
    /// Tabular, because these tick.
    static let reading = Font.system(size: 15, weight: .medium).monospacedDigit()

    /// The unit glyph trailing a numeral. Always a step quieter than the figure
    /// it qualifies — the percent sign is the axis label, not the measurement.
    static func unit(_ size: CGFloat) -> Font { .system(size: size, weight: .regular) }

    /// Prose.
    static let body = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 11, weight: .medium)

    /// Section labels. Always uppercase, always with this tracking — caps at
    /// 11pt without it set too tight to scan.
    static let label = Font.system(size: 11, weight: .bold)
    static let labelTracking: CGFloat = 0.55

    /// Scale captions sitting directly over a gauge. A step smaller and wider
    /// than `label`: at 11pt bold, three of these across the header competed
    /// with the figures they were supposed to be annotating.
    static let scaleLabel = Font.system(size: 9.5, weight: .semibold)
    static let scaleTracking: CGFloat = 0.75

    // MARK: Space — an 4pt scale used for density contrast, not uniform padding

    enum Space {
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s5: CGFloat = 20
        static let s6: CGFloat = 24
        static let s7: CGFloat = 28
        static let s8: CGFloat = 32
    }

    // MARK: Shape and motion — one language each

    static let rowRadius: CGFloat = 6

    /// Gauge height. A 4pt bar spanning the full width of the surface read as a
    /// horizontal rule that happened to be part-filled; at 7pt it reads as a
    /// thing with a quantity in it, which is the entire job.
    static let meterHeight: CGFloat = 7
    /// Gauges inside a list row, where the primary height would dominate the
    /// name beside it.
    static let meterHeightRow: CGFloat = 5

    /// Near-square. A capsule is the web-dashboard progress bar; a scale on an
    /// instrument has ends, and rounding them away is what made the empty track
    /// and the section rules read as the same object.
    static let meterRadius: CGFloat = 1.5

    // MARK: Measure — the header is a fixed grid, not a flow
    //
    // The popover's width is fixed at 420pt, so the columns can be too. Stated
    // once here because three separate rows (labels, figures, gauges) and the
    // account list below all have to land on the same verticals or the whole
    // "measured" effect collapses.

    enum Measure {
        /// The surface's single left and right margin.
        static let margin: CGFloat = 16
        /// Every secondary column, and the gauge column in the account list.
        /// The hero column is whatever is left over, so the last column is
        /// always welded to the right margin however many windows exist.
        static let column: CGFloat = 86
        /// Between columns.
        static let gutter: CGFloat = 18
        /// Ceiling on the hero gauge. Its column stretches to absorb the slack
        /// when there are fewer secondary windows; the gauge must not, or with
        /// one window it goes full-bleed and stops reading as a gauge at all.
        static let heroGauge: CGFloat = 200
        /// The account list's figure column, right-aligned against its gauge.
        static let rowValue: CGFloat = 38
        /// `.accessoryBar` buttons carry their own leading inset, which parked
        /// the footer's first glyph 11pt inboard of every other left edge on the
        /// surface. Cancelled with negative padding so the label sits on the
        /// margin and only the hover chip bleeds past it.
        static let accessoryInset: CGFloat = 11
    }

    static let meterFill = Animation.easeOut(duration: 0.35)
    static let stateChange = Animation.easeOut(duration: 0.18)
}

private extension Color {
    /// Linear blend in sRGB — good enough across the short orange→red arc, and
    /// it avoids a colour-space dependency for one gradient. Named `blended`
    /// rather than `mix` so it cannot collide with SwiftUI's own
    /// `Color.mix(with:by:)` on a newer SDK.
    func blended(with other: Color, by t: Double) -> Color {
        guard let a = NSColor(self).usingColorSpace(.sRGB),
              let b = NSColor(other).usingColorSpace(.sRGB)
        else { return self }
        return Color(nsColor: NSColor(
            srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
            green:   a.greenComponent + (b.greenComponent - a.greenComponent) * t,
            blue:    a.blueComponent + (b.blueComponent - a.blueComponent) * t,
            alpha:   1
        ))
    }
}
