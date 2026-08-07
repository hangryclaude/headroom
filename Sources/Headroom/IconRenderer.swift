import AppKit

/// Draws the app mark and writes a full `.iconset`.
///
/// Generated rather than drawn by hand so it cannot drift from the product: the
/// mark *is* the interface's central idea, rendered at icon scale.
///
/// The idea is the name. A tank filled from the bottom, and the empty space
/// above it — the headroom — is the subject. The amber tick is where the pace
/// line says the fill should be, the same notch the weekly meter carries. So a
/// glance at the icon says the same thing the app says: how much room is left,
/// and whether you are ahead of where you should be.
@MainActor
enum IconRenderer {
    /// Every size macOS asks for, and the @2x variants.
    private static let sizes: [(px: Int, name: String)] = [
        (16, "icon_16x16"), (32, "icon_16x16@2x"),
        (32, "icon_32x32"), (64, "icon_32x32@2x"),
        (128, "icon_128x128"), (256, "icon_128x128@2x"),
        (256, "icon_256x256"), (512, "icon_256x256@2x"),
        (512, "icon_512x512"), (1024, "icon_512x512@2x"),
    ]

    static func run(directory: String) {
        let root = URL(fileURLWithPath: directory).appending(path: "Headroom.iconset")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for (px, name) in sizes {
            guard let data = png(size: px) else {
                print("could not render \(name)")
                continue
            }
            try! data.write(to: root.appending(path: "\(name).png"))
        }
        print("wrote \(root.path)")
    }

    /// The menu bar mark: the same tank, drawn as a **template** image.
    ///
    /// Template images carry only an alpha channel — macOS recolours them to the
    /// menu bar's foreground, so the mark is correct in light and dark, under
    /// tinted wallpapers, and when the bar inverts. Shipping a fixed-colour icon
    /// here is the usual way to end up with a black shape invisible on a dark
    /// menu bar.
    ///
    /// Because there is only one colour available, the fill level has to read
    /// from shape alone: a hairline outline for the empty part, a solid block for
    /// the full part.
    /// - Parameter remaining: fraction of the weekly budget still available.
    ///   **Remaining, not used** — a gauge that fills up as you burn through
    ///   quota is backwards from a fuel gauge, a battery, and the app's own
    ///   name. Draining also pairs with the no-colour-when-healthy rule: a full,
    ///   silent mark means fine.
    static func menuBarImage(remaining: Double = 0.62) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let w = side * 0.52, h = side * 0.82
            let tank = CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h)
            let radius = w / 2
            let path = CGPath(roundedRect: tank.insetBy(dx: 0.75, dy: 0.75),
                              cornerWidth: radius, cornerHeight: radius, transform: nil)

            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.5)
            ctx.addPath(path)
            ctx.strokePath()

            // Solid fill from the bottom, clipped to the tank so it keeps the
            // rounded foot.
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(CGRect(x: tank.minX, y: tank.minY,
                            width: tank.width,
                            height: tank.height * max(0, min(1, remaining))))
            ctx.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func png(size: Int) -> Data? {
        guard let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        draw(in: context, size: CGFloat(size))

        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    private static func draw(in ctx: CGContext, size s: CGFloat) {
        // macOS rounds app icons at roughly 22.4% of the edge. Drawing the shape
        // ourselves rather than relying on a system mask keeps the corners right
        // in Finder, notifications, and the About box alike.
        let inset = s * 0.06
        let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let corner = rect.width * 0.224

        ctx.saveGState()
        CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
            .addToContext(ctx)
        ctx.clip()

        // Warm near-black, very slightly lifted at the top so the tile has
        // depth without a gradient anyone would call a gradient.
        let space = CGColorSpaceCreateDeviceRGB()
        let gradient = CGGradient(
            colorsSpace: space,
            colors: [
                CGColor(red: 0.13, green: 0.12, blue: 0.11, alpha: 1),
                CGColor(red: 0.06, green: 0.055, blue: 0.05, alpha: 1),
            ] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0),
            options: []
        )

        // The tank. Proportions chosen so the mark still reads at 16px, where a
        // hairline would disappear entirely.
        let tankW = s * 0.34
        let tankH = s * 0.60
        let tank = CGRect(
            x: (s - tankW) / 2,
            y: (s - tankH) / 2,
            width: tankW,
            height: tankH
        )
        let tankRadius = tankW / 2

        ctx.saveGState()
        CGPath(roundedRect: tank, cornerWidth: tankRadius, cornerHeight: tankRadius,
               transform: nil).addToContext(ctx)
        ctx.clip()

        // Empty portion — the headroom, and the reason the tile is mostly dark.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.13))
        ctx.fill(tank)

        // Filled portion, from the bottom.
        let fill: CGFloat = 0.38
        ctx.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1))
        ctx.fill(CGRect(x: tank.minX, y: tank.minY,
                        width: tank.width, height: tank.height * fill))

        // The pace tick: where spend should be. Sits above the fill here, so the
        // mark reads as "ahead of budget" -- the state worth designing for.
        let tickY = tank.minY + tank.height * 0.56
        let tickH = max(s * 0.026, 1.5)
        ctx.setFillColor(CGColor(red: 0.93, green: 0.58, blue: 0.20, alpha: 1))
        ctx.fill(CGRect(x: tank.minX, y: tickY, width: tank.width, height: tickH))

        ctx.restoreGState()
        ctx.restoreGState()
    }
}

private extension CGPath {
    func addToContext(_ ctx: CGContext) {
        ctx.addPath(self)
    }
}
