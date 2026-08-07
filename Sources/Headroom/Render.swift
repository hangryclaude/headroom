import AppKit
import SwiftUI

/// `Headroom --render <dir>` writes the popover to PNG in both appearances.
///
/// Design work needs to be looked at, and clicking a menu bar item to inspect a
/// transient popover is a poor loop -- it cannot be diffed and it cannot show
/// light and dark side by side. Rendering offscreen against the live store means
/// what gets judged is the real view with the real data in it.
@MainActor
enum Render {
    static func run(directory: String) {
        // NSHostingView needs an application object to exist; it does not need
        // one that is running.
        _ = NSApplication.shared

        let store = Store()
        let view = PopoverView(store: store, onQuit: {}, onRefresh: {}, onAddAccount: {}, onOpenPanel: {})

        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua),
                                   ("light", NSAppearance.Name.aqua)] {
            let url = URL(fileURLWithPath: directory)
                .appending(path: "popover-\(name).png")
            write(view, appearance: appearance, to: url)
            print("wrote \(url.path)")

            let panelURL = URL(fileURLWithPath: directory)
                .appending(path: "panel-\(name).png")
            write(PanelView(store: store).frame(width: 460), appearance: appearance, to: panelURL)
            print("wrote \(panelURL.path)")

            let onboardingURL = URL(fileURLWithPath: directory)
                .appending(path: "onboarding-\(name).png")
            write(OnboardingView(store: store, onFinish: {}).frame(width: 720, height: 520),
                  appearance: appearance, to: onboardingURL)
            print("wrote \(onboardingURL.path)")
        }
    }

    private static func write(_ view: some View, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("could not allocate a bitmap for \(url.lastPathComponent)")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("could not encode \(url.lastPathComponent)")
            return
        }
        try! data.write(to: url)
    }
}
