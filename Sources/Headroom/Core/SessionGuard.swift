import Darwin
import Foundation

struct LiveSession: Equatable, Identifiable {
    let pid: pid_t
    let sessionID: String
    let name: String
    let cwd: String
    let status: String      // "idle" | "busy" | "waiting", as written by Claude Code
    let startedAt: Date

    var id: pid_t { pid }
    var isBusy: Bool { status == "busy" }
}

/// Whether it is safe to change the account out from under the machine.
enum SwapVerdict: Equatable {
    case clear
    case idle([LiveSession])   // sessions exist but none mid-request
    case busy([LiveSession])   // at least one session is mid-request

    var blocksAutoSwitch: Bool { self != .clear }

    /// A manual, deliberate switch is only hard-blocked by an in-flight request.
    /// Idle sessions pick up new credentials on their next turn, so refusing
    /// those would make the feature useless -- the user always has sessions open.
    var blocksManualSwitch: Bool { if case .busy = self { return true }; return false }

    var sessions: [LiveSession] {
        switch self {
        case .clear: return []
        case .idle(let s), .busy(let s): return s
        }
    }
}

/// Reads `~/.claude/sessions/<pid>.json` and reconciles it against the OS.
///
/// The files are the wrong source of truth on their own: Claude Code does not
/// reliably remove them, so a directory listing shows sessions that died days
/// ago. Same lesson as flipoff's detector -- ask the system for process state
/// rather than trusting a record that nothing is obliged to clean up.
struct SessionGuard {
    let sessionsDir: URL

    init(sessionsDir: URL = ClaudePaths.sessionsDir) {
        self.sessionsDir = sessionsDir
    }

    func liveSessions() -> [LiveSession] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil)) ?? []

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap(Self.parse)
            .filter { Self.isClaudeRunning(pid: $0.pid) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    func verdict() -> SwapVerdict {
        let live = liveSessions()
        if live.isEmpty { return .clear }
        return live.contains(where: \.isBusy) ? .busy(live) : .idle(live)
    }

    private static func parse(_ url: URL) -> LiveSession? {
        // `pid` must be read as Int, not Int32: JSONSerialization hands back an
        // NSNumber, and the bridge only offers it as Int -- an `as? Int32` here
        // silently returns nil and every session looks dead.
        guard let data = FileManager.default.contents(atPath: url.path),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pidValue = o["pid"] as? Int,
              let sessionID = o["sessionId"] as? String
        else { return nil }
        let pid = pid_t(pidValue)

        let startedMs = o["startedAt"] as? Double ?? 0
        return LiveSession(
            pid: pid,
            sessionID: sessionID,
            name: o["name"] as? String ?? sessionID.prefix(8).description,
            cwd: o["cwd"] as? String ?? "",
            status: o["status"] as? String ?? "unknown",
            startedAt: Date(timeIntervalSince1970: startedMs / 1000)
        )
    }

    /// Liveness plus identity. `kill(pid, 0)` alone would be fooled by pid reuse,
    /// and the failure mode there is the dangerous direction: some unrelated
    /// process inherits the pid, we read it as a dead session, and we swap
    /// credentials while Claude is mid-turn. Confirming the executable really is
    /// claude closes that off without shelling out to `ps`.
    private static func isClaudeRunning(pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }

        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN))
        guard length > 0 else { return false }

        // Match the whole path, not the filename. The native installer runs
        // `~/.local/share/claude/versions/2.1.223`, so the executable is named
        // after the version and only the directory says "claude". Checking
        // lastPathComponent reports every live session as dead.
        let path = String(decoding: buffer[..<Int(length)], as: UTF8.self)
        return path.lowercased().contains("claude")
    }
}
