import AppKit
import ServiceManagement

/// Launch-at-login.
///
/// `SMAppService.mainApp.register()` silently does nothing when the app is run
/// out of a build directory -- it only means anything for a bundle in a stable
/// location such as /Applications. macOS may also park the request in
/// `requiresApproval`, which needs a one-time visit to
/// System Settings > General > Login Items. Both states are reported rather than
/// swallowed, because a toggle that flips back with no explanation is worse than
/// no toggle.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var isInstalledProperly: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications")
    }

    /// Main-actor because it can put an alert on screen. The only caller is the
    /// settings menu, which is already there -- this states the requirement
    /// rather than leaving it to hold by luck.
    @MainActor
    static func toggle() {
        if isEnabled {
            try? SMAppService.mainApp.unregister()
            return
        }

        guard isInstalledProperly else {
            warn("Move Headroom to /Applications first",
                 "Opening at login only works for an app in a stable location. "
                 + "Run ./install.sh, then try again.")
            return
        }

        do {
            try SMAppService.mainApp.register()
        } catch {
            warn("Could not enable open at login", error.localizedDescription)
            return
        }

        if SMAppService.mainApp.status == .requiresApproval {
            warn("Approve Headroom in Login Items",
                 "macOS needs this approved once in System Settings > General > Login Items.")
        }
    }

    @MainActor
    private static func warn(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
