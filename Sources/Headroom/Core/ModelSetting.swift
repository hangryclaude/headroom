import Foundation

/// The model aliases Headroom offers.
///
/// Aliases, never full model ids: `claude-opus-4-6-20260115` and its siblings are
/// dated strings that go stale on every release, whereas `opus` is resolved by
/// Claude Code at read time and keeps meaning "the newest Opus this account can
/// reach". Claude Code accepts more than these four (`best`, `opusplan`, and the
/// `[1m]` context variants); the switcher deliberately offers only the tiers that
/// map to a usage decision.
///
/// Not every account is entitled to every tier. An unentitled value is not a
/// failure state — Claude Code falls back to the tier default and says so — so
/// the picker offers the range rather than trying to predict the entitlement.
enum ClaudeModel: String, CaseIterable, Sendable {
    case fable, opus, sonnet, haiku

    var label: String {
        switch self {
        case .fable:  return "Fable"
        case .opus:   return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku:  return "Haiku"
        }
    }
}

enum ModelSettingError: Error, CustomStringConvertible {
    case unreadable(String)

    var description: String {
        switch self {
        case .unreadable(let why):
            // Overwriting a settings.json we could not parse would take the
            // user's hooks and permissions with it.
            return "refusing to write — settings.json is not readable as JSON (\(why))"
        }
    }
}

/// Reads and writes the `model` key of `~/.claude/settings.json`.
///
/// **A running session does not see this.** Claude Code resolves the model at
/// session start, so a change here takes effect for sessions launched afterwards
/// and leaves every open one on whatever it started with.
///
/// The same file holds the user's `hooks`, `permissions`, and `statusLine`, which
/// makes clobbering it the only real risk in this code. Every write is therefore
/// a read-modify-write of the live contents -- never a whole-file emit from a
/// model of what the file "should" contain -- and an unparseable file aborts the
/// write rather than replacing it.
///
/// An invalid value is not fatal at the far end: Claude Code falls back to the
/// tier default and tells the user to run `/model`. That is a reason to keep the
/// enum small, not a reason to validate defensively here.
enum ModelSetting {
    /// Not in `ClaudePaths` only because that file is owned elsewhere right now;
    /// it belongs there beside `configJSON`.
    static var settingsJSON: URL { ClaudePaths.claudeDir.appending(path: "settings.json") }

    /// nil when unset, or set to something outside our three tiers -- `opusplan`
    /// and `sonnet[1m]` are perfectly valid for Claude Code and simply are not
    /// ours to represent. Use `raw` when the UI needs to show what is really there.
    static func current(at url: URL = settingsJSON) -> ClaudeModel? {
        raw(at: url).flatMap(ClaudeModel.init(rawValue:))
    }

    /// The `model` string exactly as stored, so the UI can say "opusplan" instead
    /// of silently showing no selection.
    static func raw(at url: URL = settingsJSON) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root["model"] as? String
    }

    /// Rewrites only the `model` key, preserving every other setting.
    ///
    /// Takes the file URL so the surgery can be exercised against a copy in
    /// `--selftest`, on the same reasoning as `AccountVault.repointConfig`:
    /// destroying somebody's `hooks` block here would be silent and unrecoverable.
    ///
    /// JSONSerialization round-trips through a dictionary, so the original key
    /// order and indentation cannot survive. `.sortedKeys` at least makes the
    /// result stable across writes rather than reshuffling the file every time.
    static func set(_ model: ClaudeModel, at url: URL = settingsJSON) throws {
        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: url.path), !data.isEmpty {
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw ModelSettingError.unreadable(url.path) }
            root = existing
        }

        root["model"] = model.rawValue

        let updated = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
