import AppKit
import Foundation

/// Launches `claude /login` in a terminal the user can actually type into.
///
/// Signing in is an interactive OAuth flow — a browser round trip and a pasted
/// code — so it cannot be driven headlessly. What the app *can* do is put the
/// user in front of it with one click, and then notice when they are done.
///
/// A `.command` file opened through `NSWorkspace` is the mechanism: macOS runs
/// it in Terminal with no Automation permission and no AppleScript. Driving
/// Terminal with `tell application` would need that permission, and would be the
/// wrong terminal anyway on a machine that runs Ghostty.
enum LoginLauncher {

    enum Failure: Error, CustomStringConvertible {
        case claudeNotFound

        var description: String {
            "could not find the `claude` command — sign in manually with `claude /login`"
        }
    }

    /// Where the CLI actually lives.
    ///
    /// Resolved to an absolute path rather than relying on `PATH`: a `.command`
    /// file runs under a non-login shell, and on this machine `~/.local/bin`
    /// only reaches `PATH` via `.zshrc`. Leaving it to the shell is how this
    /// ends up as "command not found" in a window the user has to read.
    static func claudePath() -> String? {
        let candidates = [
            ClaudePaths.home.appending(path: ".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Opens a terminal sitting at the Claude login prompt.
    static func signIn() throws {
        guard let claude = claudePath() else { throw Failure.claudeNotFound }

        let script = """
        #!/bin/zsh
        clear
        echo "Sign in to the Claude account you want to add."
        echo "Headroom will offer to save it as soon as you're signed in."
        echo
        "\(claude)" /login
        status=$?
        echo
        if [ $status -eq 0 ]; then
          echo "Signed in. Switch back to Headroom — it will offer to save this account."
        else
          echo "Sign-in did not complete (exit $status). Your previous account is untouched."
        fi
        echo
        echo "You can close this window."
        """

        // A stable name in the app's own directory, so repeated sign-ins do not
        // litter the temp folder with one-shot scripts.
        let url = ClaudePaths.support.appending(path: "sign-in.command")
        try FileManager.default.createDirectory(
            at: ClaudePaths.support, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(url, configuration: config)
    }
}
