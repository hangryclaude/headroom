import AppKit
import SwiftUI

/// The first-run walkthrough's one window.
///
/// Floating, on purpose. The middle of this flow sends the user into a browser
/// to sign in, and a `.accessory` app has no Dock icon and no ⌘-Tab entry — a
/// window that slips behind Safari is genuinely unrecoverable, not merely
/// annoying. `.floating` removes the whole failure class for the cost of one
/// line.
///
/// Fixed size and not resizable: every screen here is laid out to a 624pt
/// measure, and there is nothing on any of them that a taller window would show
/// more of.
@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {

    /// Self-retention while on screen.
    ///
    /// The flow outlives the call that started it — it spans a browser round
    /// trip and a network exchange — so it cannot depend on the caller keeping a
    /// property alive for the duration. Dropped in `windowWillClose`, which is
    /// the one exit every path funnels through.
    private static var live: [OnboardingWindow] = []

    private let store: Store
    private let onFinish: (() -> Void)?
    private var window: NSWindow?
    private var hasFinished = false

    /// - Parameter onFinish: called once, when the walkthrough ends by any route
    ///   — Finish, Skip, or the close button. This is where the caller records
    ///   that first run is over.
    init(store: Store, onFinish: (() -> Void)? = nil) {
        self.store = store
        self.onFinish = onFinish
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil { window = makeWindow() }
        if !Self.live.contains(where: { $0 === self }) { Self.live.append(self) }

        // `.accessory` apps are never made frontmost for free. Without this the
        // window opens behind whatever the user was working in and reads as the
        // menu item having done nothing at all.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    // MARK: Window

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Headroom"
        // The screens carry their own headline; a title bar caption above it
        // says the same word twice.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.delegate = self

        // `[weak self]` because the hosting view is owned by the window, which is
        // owned by this object — a strong capture closes the loop and neither
        // ever goes away.
        window.contentView = NSHostingView(
            rootView: OnboardingView(store: store) { [weak self] in self?.close() }
        )
        window.center()
        return window
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard !hasFinished else { return }
        hasFinished = true
        onFinish?()
        Self.live.removeAll { $0 === self }
    }
}
