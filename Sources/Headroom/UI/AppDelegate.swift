import AppKit
import SwiftUI
import UserNotifications

/// AppKit rather than SwiftUI's `MenuBarExtra`.
///
/// `MenuBarExtra` renders its label as a template, which flattens colour. The
/// whole design rests on the bar staying neutral until something is actually
/// wrong and then going amber, so setting the title colour is non-negotiable.
/// `NSStatusItem.button.attributedTitle` can do it; `MenuBarExtra` cannot.
/// An earlier tool reached the same conclusion.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSWindow?
    private var onboarding: OnboardingWindow?

    /// The dropdown is an `NSMenu` carrying one full-width custom view, not an
    /// `NSPopover`.
    ///
    /// A popover is its own window: it floats below the menu bar with a gap and
    /// an arrow, and reads as a panel that happens to be near the icon. A menu
    /// is drawn by the menu bar itself — it drops welded to the item with no gap
    /// and no arrow, which is the "grows out of the bar" look. Same reason
    /// CodexBar uses a menu.
    private var menu: NSMenu?
    private let store = Store()
    private var lastNotifiedVerdict: Verdict?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        // Left click opens the popover, right click opens settings. Keeps the
        // popover free of a settings row it would otherwise have to carry.
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }

        store.start()
        render()
        showOnboardingIfFirstRun()

        // The store mutates on a timer and AppKit will not observe it, so the
        // status item redraws on the same cadence.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.render()
                self?.notifyIfNeeded()
                self?.announceAutoSwapIfNeeded()
            }
        }
    }

    // MARK: Status item

    private func render() {
        guard let button = statusItem.button else { return }

        // A template image, so macOS recolours the mark to whatever the menu bar
        // needs — black on a light bar, white on a dark one, correct over a
        // tinted wallpaper. It drains as the week is spent, so the icon alone
        // carries the reading even in `.dot` mode.
        button.image = IconRenderer.menuBarImage(
            remaining: 1 - Double(store.weeklyPercent ?? 0) / 100)
        button.imagePosition = store.settings.menuBarMode == .dot
            ? .imageOnly : .imageLeading
        button.imageHugsTitle = true

        let colour = store.headlineAccent.map(NSColor.init) ?? .labelColor
        // Staleness dims the *number*, never below legibility, and never the
        // icon. An earlier version dropped the whole item to 40% opacity, which
        // on this machine meant the menu bar was faint most of the time — the
        // quota cache only refreshes when Claude Code talks to the server, so
        // "stale" is the resting state, not an exception.
        let alpha: CGFloat = store.isStale ? 0.75 : 1.0

        button.attributedTitle = NSAttributedString(
            string: title(),
            attributes: [
                // Tabular figures, or the title reflows every second as digits
                // change width and the whole bar jitters.
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: colour.withAlphaComponent(alpha),
            ]
        )
        button.toolTip = tooltip()
    }

    private func title() -> String {
        let weekly = store.weeklyPercent.map { "\($0)%" }
        let session = store.sessionPercent.map { "\($0)%" }
        let remaining = store.session?.timeRemaining(now: store.now).map(Format.countdown)

        switch store.settings.menuBarMode {
        case .weekly:    return weekly ?? "—"
        case .session:   return session ?? "—"
        case .both:      return [weekly, session].compactMap { $0 }.joined(separator: " · ")
        case .countdown: return remaining ?? "—"
        // The icon is the indicator; no glyph needed alongside it.
        case .dot:       return ""
        }
    }

    private func tooltip() -> String {
        var lines: [String] = []
        if let weekly = store.weeklyPercent {
            // The glyph drains and the number counts up, so say both directions
            // in the one place there is room for a full sentence.
            lines.append("\(weekly)% of the week used — \(100 - weekly)% left")
        }
        if let freshness = store.freshness { lines.append(freshness) }
        lines.append("")
        lines.append(contentsOf: [store.decision.verdict.headline, store.decision.why])
        if let identity = store.identity {
            lines.append("")
            lines.append("\(identity.email) · \(identity.planLabel)")
        }
        if store.isStale, let quota = store.quota {
            lines.append("cache \(Format.ago(quota.age(now: store.now))) old")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Notifications

    /// Fires once per verdict change, never on a timer. The point is to catch the
    /// moment the situation changes, not to nag.
    private func notifyIfNeeded() {
        guard store.settings.notifyOnDecision else { return }
        let verdict = store.decision.verdict
        guard verdict != lastNotifiedVerdict else { return }
        guard verdict == .swap || verdict == .rotateSoon || verdict == .allHot else {
            lastNotifiedVerdict = verdict
            return
        }
        lastNotifiedVerdict = verdict

        let content = UNMutableNotificationContent()
        content.title = verdict.headline
        content.body = store.decision.why

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Announces a swap auto mode performed, so the account never changes
    /// silently underneath the user.
    private var announcedAutoSwap: Date?

    private func announceAutoSwapIfNeeded() {
        guard let swap = store.lastAutoSwap, swap.at != announcedAutoSwap else { return }
        announcedAutoSwap = swap.at

        let content = UNMutableNotificationContent()
        content.title = "Switched to \(store.label(for: swap.name))"
        content.body = store.decision.why
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Accounts

    /// Saves the current account, and optionally goes on to add another.
    ///
    /// The ordering is the safety property. Every Claude account on the machine
    /// shares one Keychain item, so `claude /login` overwrites whatever is
    /// currently stored — sign in before the current credential is in the vault
    /// and it is gone for good. So: save, verify the save, and only then launch.
    ///
    /// The login itself stays interactive (a browser round trip; it cannot be
    /// driven headlessly), but the app opens the terminal at the prompt and then
    /// notices the new account on its own — see `Store.unsavedAccount`.
    // MARK: Onboarding

    /// Keyed on the walkthrough having been *finished*, not on the app having
    /// launched. Someone who quits halfway through has not been onboarded, and
    /// the alternative — a flag set at launch — would silently strand them with
    /// an empty vault and no route back to the flow.
    private static let onboardedKey = "completedOnboarding"

    private func showOnboardingIfFirstRun() {
        guard !UserDefaults.standard.bool(forKey: Self.onboardedKey) else { return }
        // An existing vault means the accounts were set up before this flow
        // shipped. Showing it then would be a walkthrough of work already done.
        guard store.accounts.isEmpty else {
            UserDefaults.standard.set(true, forKey: Self.onboardedKey)
            return
        }
        showOnboarding()
    }

    @objc private func showOnboarding() {
        let window = OnboardingWindow(store: store) {
            UserDefaults.standard.set(true, forKey: Self.onboardedKey)
        }
        onboarding = window
        window.show()
    }

    private func addAccount() {
        dismissDropdown()
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Add a Claude account"
        alert.informativeText = """
            Your browser will open so you can sign in. The account you are using now             stays signed in — nothing is swapped.

            Anthropic will show you a code. Paste it back here.
            """
        alert.addButton(withTitle: "Open Browser")
        alert.addButton(withTitle: "Save the Current Account Instead")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:  beginBrowserSignIn()
        case .alertSecondButtonReturn: saveCurrentAccount()
        default:                       return
        }
    }

    /// The browser sign-in, start to finish, without a terminal.
    ///
    /// The old flow shelled out to `claude /login`, which authenticates into the
    /// single Keychain slot every Claude account on the machine shares -- so
    /// adding an account meant signing out of the one in use, and the vault copy
    /// of the outgoing account had better have been current or its token was
    /// stranded. `OAuthFlow` talks to Anthropic directly and hands the tokens
    /// straight to the vault, so the live session is never disturbed.
    private func beginBrowserSignIn() {
        let pending = OAuthFlow.begin()
        NSWorkspace.shared.open(pending.url)

        let alert = NSAlert()
        alert.messageText = "Paste the code"
        alert.informativeText = """
            Sign in as the account you want to add, then paste the code Anthropic             shows you.
            """
        alert.addButton(withTitle: "Add Account")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "paste the code here"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let pasted = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pasted.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let account = try await self.store.addAccount(pasted: pasted, pending: pending)
                self.report(
                    "Added \(account.email ?? account.name)",
                    "\(account.plan ?? "—") — saved and ready to switch to.",
                    detail: "The account you were using is still signed in. Nothing was swapped."
                )
            } catch {
                self.report("Could not add that account", error.localizedDescription,
                            detail: "Nothing changed. The code is single-use, so start again "
                                  + "from Add Account to get a fresh one.")
            }
        }
    }

    /// Files whichever account is signed in right now.
    ///
    /// Still worth keeping: an account that was added by `claude /login` outside
    /// Headroom has no vault entry, and this is how it gets one.
    private func saveCurrentAccount() {
        guard let identity = store.identity else {
            signInPrompt()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Save \(identity.email)"
        alert.informativeText = "\(identity.planLabel). Give it a name you'll recognise in the list."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = suggestedName(for: identity)
        field.placeholderString = "work"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.captureCurrentAccount(named: name)

        if let problem = store.lastSwapError {
            report("Could not save this account", problem,
                   detail: "Nothing changed.")
        }
    }

    private func report(_ title: String, _ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "\(message)\n\n\(detail)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// A name that is not already taken, so saving twice never silently
    /// overwrites a different account's credential.
    private func suggestedName(for identity: Identity) -> String {
        let taken = Set(store.accounts.map(\.name))
        let base = identity.handle
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    private func signInPrompt() {
        let alert = NSAlert()
        alert.messageText = "Not signed in to Claude Code"
        alert.informativeText =
            "Sign in first — Headroom will offer to save the account once you are."
        alert.addButton(withTitle: "Sign In…")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { beginBrowserSignIn() }
    }


    // MARK: Popover

    @objc private func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showSettingsMenu()
        } else {
            showDropdown()
        }
    }

    /// Presents the reading as a menu welded to the status item.
    ///
    /// `statusItem.menu` is set only for the duration of the click and cleared
    /// straight after: leaving it assigned makes AppKit swallow the button's
    /// action, so the right-click settings path would stop firing.
    private func showDropdown() {
        store.refresh()

        let menu = NSMenu()
        menu.delegate = self

        let host = NSHostingView(
            rootView: PopoverView(
                store: store,
                onQuit: { NSApp.terminate(nil) },
                onRefresh: { [weak self] in
                    self?.dismissDropdown()
                    self?.store.refresh()
                    Task { await self?.store.refreshUsage(force: true) }
                },
                onAddAccount: { [weak self] in
                    self?.dismissDropdown()
                    self?.addAccount()
                },
                onOpenPanel: { [weak self] in
                    self?.dismissDropdown()
                    self?.showPanel()
                }
            )
        )
        // A menu item will not size a SwiftUI view for you — without an explicit
        // frame the row collapses to zero height and the menu looks empty.
        host.frame.size = host.fittingSize

        let item = NSMenuItem()
        item.view = host
        menu.addItem(item)

        self.menu = menu
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func dismissDropdown() {
        menu?.cancelTracking()
        menu = nil
    }

    /// Settings as a menu rather than a window. Everything here is a toggle or a
    /// pick-one, and a preferences window for six switches is ceremony.
    private func showSettingsMenu() {
        let menu = NSMenu()

        let modeItem = NSMenuItem(title: "Menu bar shows", action: nil, keyEquivalent: "")
        modeItem.isEnabled = false
        menu.addItem(modeItem)
        for mode in MenuBarMode.allCases {
            let item = NSMenuItem(
                title: "  \(mode.title)", action: #selector(setMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = store.settings.menuBarMode == mode ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let notify = NSMenuItem(
            title: "Notify when the verdict changes",
            action: #selector(toggleNotify(_:)), keyEquivalent: "")
        notify.target = self
        notify.state = store.settings.notifyOnDecision ? .on : .off
        menu.addItem(notify)

        let auto = NSMenuItem(
            title: "Swap automatically", action: #selector(toggleAutoSwap(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = store.settings.autoSwap ? .on : .off
        // Even on, this never fires while a session is mid-request.
        auto.toolTip = "Only ever swaps when no session is mid-request"
        menu.addItem(auto)

        menu.addItem(.separator())

        let login = NSMenuItem(
            title: "Open at login", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let details = NSMenuItem(title: "Details…", action: #selector(showPanel), keyEquivalent: "d")
        details.target = self
        menu.addItem(details)

        let setup = NSMenuItem(
            title: "Set Up Accounts…", action: #selector(showOnboarding), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Headroom", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // The menu has to be detached again or it hijacks the left click.
        statusItem.menu = nil
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = MenuBarMode(rawValue: raw) else { return }
        store.settings.menuBarMode = mode
        render()
    }

    @objc private func toggleNotify(_ sender: Any?) {
        store.settings.notifyOnDecision.toggle()
    }

    @objc private func toggleAutoSwap(_ sender: Any?) {
        store.settings.autoSwap.toggle()
    }

    @objc private func toggleLoginItem(_ sender: Any?) {
        LoginItem.toggle()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// The detail window. Created lazily and kept alive across opens so the
    /// scroll position and window frame survive being closed.
    ///
    /// `.accessory` apps do not get focus for free, so the activate call is
    /// required — without it the window appears behind whatever the user was
    /// working in, which reads as the menu item having done nothing.
    @objc func showPanel() {
        dismissDropdown()

        if panel == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Headroom"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(rootView: PanelView(store: store))
            panel = window
        }

        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    // MARK: NSMenuDelegate

    func menuDidClose(_ menu: NSMenu) {
        self.menu = nil
    }
}
