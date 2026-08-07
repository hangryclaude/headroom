import AppKit
import SwiftUI

/// First run, in three screens: welcome → add an account → done.
///
/// "Add another" loops back to the middle screen, so the flow has no idea how
/// many accounts the user owns and never pretends to. There is no progress bar
/// and no "one more to go" — the person decides when they are finished, and the
/// Finish button is on screen from the moment the first account lands.
///
/// The one failure that had to be designed for: a pasted code expires in about
/// two minutes, which is easily spent reading a sign-in page. So every failure
/// state keeps the user on this screen with a **Get a new link** button beside
/// the message. Nothing here ever sends them back to the start.
struct OnboardingView: View {

    // The popover's 420pt grid does not carry over to a 720pt window, so this
    // screen states its own margins once rather than stacking Theme.Space steps.
    private enum Page {
        static let side: CGFloat = 48
        static let top: CGFloat = 40
        static let bottom: CGFloat = 32
        static let title: CGFloat = 30
        static let subtitle: CGFloat = 22
        /// The widest the text column is allowed to get. Prose set across a
        /// 27-inch display is unreadable however much room there is.
        static let measure: CGFloat = 720
    }

    @State private var model: OnboardingModel
    @FocusState private var codeFocused: Bool

    /// Lets the window follow the flow: full screen to introduce and to finish,
    /// a corner panel while the browser is the thing that matters.
    private let onStepChange: ((OnboardingModel.Step) -> Void)?

    init(store: Store,
         onStepChange: ((OnboardingModel.Step) -> Void)? = nil,
         onFinish: @escaping () -> Void) {
        _model = State(initialValue: OnboardingModel(store: store, onFinish: onFinish))
        self.onStepChange = onStepChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stages
                .padding(.bottom, Theme.Space.s8)

            switch model.step {
            case .welcome: welcome
            case .paste:   paste
            case .done:    done
            }

            Spacer(minLength: Theme.Space.s6)
            footer
        }
        .padding(.horizontal, Page.side)
        .padding(.top, Page.top)
        .padding(.bottom, Page.bottom)
        // A measure, not a window size. Full screen the content still has to
        // stop at a readable line length; what grows is the space around it.
        .frame(maxWidth: Page.measure, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .onChange(of: model.step) { _, step in onStepChange?(step) }
        .onDisappear { model.stopWatchingClipboard() }
    }

    // MARK: Chrome

    private var stages: some View {
        HStack(spacing: Theme.Space.s2) {
            stage("WELCOME", .welcome)
            separator
            stage("ACCOUNT", .paste)
            separator
            stage("DONE", .done)
        }
    }

    private func stage(_ title: String, _ step: OnboardingModel.Step) -> some View {
        Text(title)
            .font(Theme.label)
            .tracking(Theme.labelTracking)
            .foregroundStyle(model.step == step ? Theme.ink : Theme.inkTertiary)
    }

    private var separator: some View {
        Text("·")
            .font(Theme.label)
            .foregroundStyle(Theme.inkTertiary)
    }

    /// A borderless button. `.link` would be the obvious style and is wrong here:
    /// it paints its label in the system accent, and a healthy screen in this app
    /// carries no colour at all.
    private func quietButton(
        _ title: String, font: Font = Theme.caption, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(font)
                .foregroundStyle(Theme.inkSecondary)
                .underline()
        }
        .buttonStyle(.plain)
    }

    private var rule: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 96, height: 1)
            .padding(.vertical, Theme.Space.s5)
    }

    private func heading(_ text: String, size: CGFloat) -> some View {
        Text(text)
            .font(Theme.numeral(size))
            .tracking(Theme.numeralTracking(size))
            .foregroundStyle(Theme.ink)
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(Theme.reading)
            .foregroundStyle(Theme.inkSecondary)
    }

    private func numbered(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s4) {
            Text("\(index)")
                .font(Theme.value)
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: 12, alignment: .trailing)
            Text(text)
                .font(Theme.reading)
                .foregroundStyle(Theme.ink)
        }
    }

    // MARK: Screen 1 — welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Headroom", size: Page.title)
            line("Your Claude quota, in the menu bar.")
                .padding(.top, Theme.Space.s2)

            rule

            Text("TWO THINGS")
                .font(Theme.label)
                .tracking(Theme.labelTracking)
                .foregroundStyle(Theme.inkTertiary)
                .padding(.bottom, Theme.Space.s3)

            VStack(alignment: .leading, spacing: Theme.Space.s3) {
                numbered(1, "Shows how much of your week is left.")
                numbered(2, "Switches between your Claude accounts.")
            }

            VStack(alignment: .leading, spacing: Theme.Space.s2) {
                line("For the second one it needs your accounts.")
                line("Adding one takes about a minute.")
                line("Nothing you are signed into now gets signed out.")
            }
            .padding(.top, Theme.Space.s7)
        }
    }

    // MARK: Screen 2 — sign in and paste

    private var paste: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Sign in, then paste the code", size: Page.subtitle)

            VStack(alignment: .leading, spacing: Theme.Space.s3) {
                numbered(1, "Your browser just opened.")
                numbered(2, "Sign in as the account you want to add.")
                numbered(3, "Copy the code it shows you.")
                numbered(4, "It lands in the box below on its own.")
            }
            .padding(.top, Theme.Space.s6)

            codeField
                .padding(.top, Theme.Space.s7)

            Text(model.status)
                .font(Theme.caption)
                .foregroundStyle(Theme.inkTertiary)
                .padding(.top, Theme.Space.s2)

            if let failure = model.failure {
                trouble(failure)
                    .padding(.top, Theme.Space.s5)
            } else {
                HStack(spacing: Theme.Space.s4) {
                    Text("Nothing happened?")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkTertiary)
                    quietButton("Open the link again") { model.newLink() }
                    quietButton("Copy the link") { model.copyLink() }
                }
                .padding(.top, Theme.Space.s5)
            }
        }
    }

    private var codeField: some View {
        TextField("", text: $model.code)
            .textFieldStyle(.plain)
            .font(Theme.value)
            .foregroundStyle(Theme.ink)
            .focused($codeFocused)
            .onSubmit { model.submit() }
            .disabled(model.isAdding)
            .padding(.horizontal, Theme.Space.s3)
            .frame(width: 520, height: 34, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.rowRadius)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
            .onAppear { codeFocused = true }
    }

    /// The only place on this screen that is allowed colour, and only because
    /// something is actually wrong — the same borrowed-ramp move the swap-error
    /// label makes in the popover.
    private func trouble(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            Text(message)
                .font(Theme.body)
                .foregroundStyle(Theme.accent(for: 100) ?? Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Codes stop working after about two minutes. Get a fresh one and try again.")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkTertiary)
            HStack(spacing: Theme.Space.s3) {
                Button("Get a new link") { model.newLink() }
                    .buttonStyle(.bordered)
                quietButton("Copy the link") { model.copyLink() }
            }
            .padding(.top, Theme.Space.s1)
        }
        .frame(width: 520, alignment: .leading)
    }

    // MARK: Screen 3 — done

    private var done: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("You're set up", size: Page.title)

            rule

            line(model.savedSummary)
            if let added = model.addedLabel {
                Text(added)
                    .font(Theme.value)
                    .foregroundStyle(Theme.ink)
                    .padding(.top, Theme.Space.s2)
            }

            VStack(alignment: .leading, spacing: Theme.Space.s2) {
                line("Click the icon in the menu bar for the numbers.")
                line("Right-click it for settings.")
            }
            .padding(.top, Theme.Space.s7)

            Text("Add every account you want to switch between.")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkTertiary)
                .padding(.top, Theme.Space.s5)
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch model.step {
            case .welcome:
                quietButton("Skip for now", font: Theme.body) { model.finish() }
                Spacer()
                Button("Add an account") { model.startAdding() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)

            case .paste:
                quietButton("Back", font: Theme.body) { model.cancelAdding() }
                    .disabled(model.isAdding)
                Spacer()
                Button(model.isAdding ? "Adding…" : "Add account") { model.submit() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSubmit)

            case .done:
                Button("Add another") { model.startAdding() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Finish") { model.finish() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The walkthrough's state, kept out of the view so the browser round trip and
/// the code exchange are not tangled up in layout.
@MainActor
@Observable
final class OnboardingModel {

    enum Step { case welcome, paste, done }

    private let store: Store
    private let onFinish: () -> Void

    var step: Step = .welcome
    var code: String = ""
    private(set) var isAdding = false
    private(set) var failure: String?
    private(set) var addedLabel: String?
    private(set) var pastedFromClipboard = false

    private var pending: OAuthFlow.Pending?
    private var clipboardTimer: Timer?
    private var lastChangeCount = 0

    init(store: Store, onFinish: @escaping () -> Void) {
        self.store = store
        self.onFinish = onFinish
    }

    // MARK: Derived

    var canSubmit: Bool {
        !isAdding && pending != nil
            && !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var status: String {
        if isAdding { return "Adding the account…" }
        if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Waiting for the code."
        }
        return pastedFromClipboard ? "Copied from your clipboard." : "Ready."
    }

    var savedSummary: String {
        let count = store.accounts.count
        return count == 1 ? "1 account saved." : "\(count) accounts saved."
    }

    // MARK: Steps

    func startAdding() {
        step = .paste
        addedLabel = nil
        newLink()
    }

    func cancelAdding() {
        stopWatchingClipboard()
        pending = nil
        code = ""
        failure = nil
        step = store.accounts.isEmpty ? .welcome : .done
    }

    func finish() {
        stopWatchingClipboard()
        onFinish()
    }

    /// A fresh sign-in link, from anywhere. This is the recovery path: an expired
    /// code, a browser that never opened, a sign-in as the wrong account — all of
    /// them are one click from a working link without leaving the screen.
    func newLink() {
        let pending = OAuthFlow.begin()
        self.pending = pending
        code = ""
        failure = nil
        pastedFromClipboard = false
        NSWorkspace.shared.open(pending.url)
        startWatchingClipboard()
    }

    func copyLink() {
        guard let pending else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(pending.url.absoluteString, forType: .string)
        // Our own write would otherwise come straight back as a pasted code.
        lastChangeCount = board.changeCount
    }

    func submit() {
        guard canSubmit, let pending else { return }
        let pasted = code.trimmingCharacters(in: .whitespacesAndNewlines)
        isAdding = true
        failure = nil

        // `addAccount` suspends across a 30s network call and has no in-flight
        // guard of its own, so `isAdding` is doing real work here, not just
        // dimming a button.
        Task { @MainActor in
            do {
                let account = try await store.addAccount(pasted: pasted, pending: pending)
                isAdding = false
                addedLabel = account.label
                self.pending = nil
                code = ""
                stopWatchingClipboard()
                step = .done
            } catch {
                isAdding = false
                failure = Self.plainly(error)
            }
        }
    }

    /// `VaultError` is `CustomStringConvertible` but not `LocalizedError`, so
    /// `localizedDescription` turns a perfectly good sentence into "The operation
    /// couldn't be completed."
    private static func plainly(_ error: Error) -> String {
        if let flow = error as? OAuthFlow.FlowError {
            return flow.errorDescription ?? "That code didn't work."
        }
        if let vault = error as? VaultError { return String(describing: vault) }
        let described = (error as NSError).localizedDescription
        return described.isEmpty ? String(describing: error) : described
    }

    // MARK: Clipboard

    /// The code arrives by itself.
    ///
    /// This is not a convenience. An `LSUIElement` app has no main menu, so ⌘V
    /// has no responder path and fails *silently* in the field below — which
    /// reads as the app being broken. Watching the pasteboard makes the common
    /// path work without a keystroke; right-click ▸ Paste still covers the rest.
    private func startWatchingClipboard() {
        lastChangeCount = NSPasteboard.general.changeCount
        clipboardTimer?.invalidate()
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollClipboard() }
        }
    }

    func stopWatchingClipboard() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
    }

    private func pollClipboard() {
        let board = NSPasteboard.general
        guard board.changeCount != lastChangeCount else { return }
        lastChangeCount = board.changeCount

        guard !isAdding,
              let text = board.string(forType: .string),
              let found = Self.extractCode(from: text)
        else { return }

        code = found
        pastedFromClipboard = true
        failure = nil
    }

    /// The three shapes people actually produce: the code, the code with its
    /// check value, or the whole callback address out of the browser bar.
    /// Anything else is ignored in silence — nagging at every unrelated copy
    /// while someone is working in a browser is worse than missing one.
    static func extractCode(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 4096 else { return nil }

        if trimmed.lowercased().hasPrefix("http"),
           let items = URLComponents(string: trimmed)?.queryItems,
           let code = items.first(where: { $0.name == "code" })?.value,
           !code.isEmpty {
            if let state = items.first(where: { $0.name == "state" })?.value, !state.isEmpty {
                return "\(code)#\(state)"
            }
            return code
        }

        let parts = trimmed.split(separator: "#", maxSplits: 1)
        guard let code = parts.first, code.count >= 16, isCodeShaped(code) else { return nil }
        if parts.count == 2 {
            guard parts[1].count >= 8, isCodeShaped(parts[1]) else { return nil }
        }
        return trimmed
    }

    private static func isCodeShaped(_ text: Substring) -> Bool {
        text.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber || character == "-" || character == "_"
        }
    }
}
