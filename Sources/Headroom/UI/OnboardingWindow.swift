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
/// The frame follows the step rather than staying put — see `applyFrame`. Full
/// screen to introduce and to finish; a corner panel for the one step that has
/// to share the display with a browser.
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
            rootView: OnboardingView(
                store: store,
                onStepChange: { [weak self] step in self?.move(to: step) },
                onFinish: { [weak self] in self?.close() }
            )
        )
        applyFrame(for: .welcome, to: window, animate: false)
        return window
    }

    /// The walkthrough opens and closes filling the screen, and gets out of the
    /// way in between.
    ///
    /// Covering the screen is the right frame for the two steps that are only
    /// about reading — nothing competes with them. It is the wrong frame for the
    /// paste step, which needs the browser and this window legible at the same
    /// moment: full screen either hides the page holding the code or ends up
    /// behind it, and `.accessory` apps have no Dock icon or ⌘-Tab entry to dig a
    /// buried window back out. So that one step shrinks to a corner instead.
    private func move(to step: OnboardingModel.Step) {
        guard let window else { return }
        applyFrame(for: step, to: window, animate: true)
    }

    private func applyFrame(for step: OnboardingModel.Step, to window: NSWindow, animate: Bool) {
        // `.main` is the screen with the key window, which during this flow can
        // be the browser's. The walkthrough should stay where it opened.
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        switch step {
        case .welcome, .done:
            window.setFrame(visible, display: true, animate: animate)
        case .paste:
            let size = NSSize(width: 460, height: 520)
            let inset: CGFloat = 24
            let frame = NSRect(
                x: visible.maxX - size.width - inset,
                y: visible.maxY - size.height - inset,
                width: size.width,
                height: size.height)
            window.setFrame(frame, display: true, animate: animate)
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard !hasFinished else { return }
        hasFinished = true
        onFinish?()
        Self.live.removeAll { $0 === self }
    }
}
