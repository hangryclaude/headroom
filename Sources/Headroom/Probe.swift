import Foundation

/// `Headroom --probe` prints everything the app reads, in the order it reads it.
///
/// The point is to be able to diff the app's understanding of the data against
/// `jq` on the same files. Without a GUI test harness that is the only honest way
/// to know the parsing is right, and every field the UI shows should be provable
/// here first.
enum Probe {
    static func run() {
        let now = Date()

        print("QUOTA  \(ClaudePaths.configJSON.path)")
        do {
            let snap = try QuotaReader().read(now: now)
            let age = Int(snap.age(now: now))
            let staleMark = snap.isStale(now: now) ? "  ** STALE **" : ""
            print("  fetched   \(fmt(snap.fetchedAt))  (\(age)s ago)\(staleMark)")
            print("  account   \(snap.accountUUID?.prefix(8) ?? "—")")

            for limit in snap.limits {
                let value: String
                switch limit.reading {
                case .live(let p):  value = "\(p)%"
                case .rolledOver:   value = "reset (window elapsed, true value unknown)"
                case .unknown:      value = "—"
                }
                let resets = limit.resetsAt.map(fmt) ?? "—"
                let remaining = limit.timeRemaining(now: now).map { "  in \(duration($0))" } ?? ""
                print("  \(limit.kind.label.padded(8)) \(value.padded(46)) resets \(resets)\(remaining)")
            }
        } catch {
            print("  ERROR  \(error)")
        }

        print("")
        print("SESSIONS  \(ClaudePaths.sessionsDir.path)")
        let guard_ = SessionGuard()
        let live = guard_.liveSessions()
        for s in live {
            print("  \(String(s.pid).padded(7)) \(s.status.padded(8)) \(s.name.padded(34)) \(s.cwd)")
        }
        let verdict = guard_.verdict()
        print("  \(live.count) live")
        switch verdict {
        case .clear:
            print("  VERDICT  clear — safe to swap")
        case .idle(let s):
            print("  VERDICT  \(s.count) idle — manual swap ok, auto-switch held")
        case .busy(let s):
            let busy = s.filter(\.isBusy).map(\.name).joined(separator: ", ")
            print("  VERDICT  busy — swap blocked by: \(busy)")
        }

        print("")
        print("TRANSCRIPTS  \(ClaudePaths.projectsDir.path)")
        let indexer = TranscriptIndexer()
        let started = Date()
        let added = indexer.refresh(now: now)
        let elapsed = Date().timeIntervalSince(started)
        print("  scan      \(String(format: "%.2f", elapsed))s")
        print("  ingested  \(added.total.formatted()) tokens this pass")

        for window in [(1.0, "1h"), (5.0, "5h"), (24.0, "24h")] {
            let since = now.addingTimeInterval(-window.0 * 3600)
            let usage = indexer.total(since: since, now: now)
            print("  \(window.1.padded(6)) in \(usage.input.formatted().padded(12)) out \(usage.output.formatted().padded(12)) cacheR \(usage.cacheRead.formatted().padded(14)) cacheW \((usage.cacheWrite5m + usage.cacheWrite1h).formatted())")
        }

        let byModel = indexer.usage(since: now.addingTimeInterval(-24 * 3600), now: now)
        for (model, usage) in byModel.sorted(by: { $0.value.total > $1.value.total }) {
            print("  \(model.padded(22)) \(usage.total.formatted()) tokens")
        }

        let rate = indexer.burnRate(window: 3600, now: now)
        print("  burn      \(Int(rate).formatted()) tok/min (last hour)")
    }

    private static func fmt(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    private static func duration(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

extension String {
    /// Column padding for the CLI surfaces (probe and vault).
    func padded(_ n: Int) -> String {
        count >= n ? self : self + String(repeating: " ", count: n - count)
    }
}
