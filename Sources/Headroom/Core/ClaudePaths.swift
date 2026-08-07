import Foundation

/// Every location Headroom reads. Collected in one place because Claude Code's
/// layout is undocumented and shifts between releases -- when something moves,
/// this is the only file that should need editing.
enum ClaudePaths {
    /// `HEADROOM_HOME` retargets every path below at a throwaway directory.
    ///
    /// `homeDirectoryForCurrentUser` resolves through `getpwuid`, so unlike most
    /// Unix tooling it ignores `$HOME` and there is no way to point a test run at
    /// a fixture tree from the outside. That matters for the screenshots in the
    /// README: rendered against the real store they would publish the owner's
    /// account addresses.
    static let home: URL = {
        if let override = ProcessInfo.processInfo.environment["HEADROOM_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    /// Identity, per-project state, and the quota cache all share this one file.
    /// It is rewritten by Claude Code on every run, so anything we write here has
    /// to be a read-modify-write against the current contents, never a whole-file
    /// copy from a snapshot.
    static var configJSON: URL { home.appending(path: ".claude.json") }

    static var claudeDir: URL { home.appending(path: ".claude") }

    /// One file per running process, named `<pid>.json`. Claude Code does not
    /// always clean these up, so a file here means "a session once existed",
    /// not "a session is running" -- SessionGuard checks the pid against the OS.
    static var sessionsDir: URL { claudeDir.appending(path: "sessions") }

    /// Transcripts: `projects/<mangled-cwd>/<sessionId>.jsonl`, plus subagent
    /// journals nested deeper. 600+ MB here, so only ever tailed by byte offset.
    static var projectsDir: URL { claudeDir.appending(path: "projects") }

    /// Headroom's own state. Deliberately outside `.claude/` -- that directory is
    /// a git repo the user tracks, and our cursors and snapshots are pure noise in it.
    static var support: URL {
        home.appending(path: "Library/Application Support/Headroom")
    }

    /// caam's vault layout, reused verbatim so `caam ls` keeps working alongside
    /// Headroom instead of the two tools fighting over the same accounts.
    static var vault: URL {
        home.appending(path: ".local/share/caam/vault/claude")
    }

    /// Service name of the Keychain item holding the OAuth token set. The account
    /// attribute is the *Unix username*, not the Claude email, so every Claude
    /// account on this machine collides on this single item -- which is precisely
    /// why swapping has to be an explicit read/stash/write rather than a file move.
    static let keychainService = "Claude Code-credentials"
}
