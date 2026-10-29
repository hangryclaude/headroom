# Headroom Spend (Tokens) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A popover section showing all-time / this-month / today token totals (all accounts = this Mac), backfilled from full transcript history, with estimated API value as a footnote.

**Architecture:** A second `TranscriptIndexer` instance ("spend indexer") with its own config and state file: backfills from byte 0, buckets by UTC hour, dedupes requests persistently, never prunes. The live 5-minute quota indexer is untouched — its config defaults reproduce today's behavior exactly. Dollars are computed at render time from `Pricing`; storage is tokens only.

**Tech Stack:** Swift 6 / SwiftPM, zero dependencies, AppKit+SwiftUI. Tests live in `SelfTest.swift` (run via the binary, not a test target).

## Global Constraints

- **NO git commits, no install, no push** — standing instruction 2026-08-19. Every task's "commit" checkpoint is replaced by: `swift build 2>&1 | tail -3` clean + `.build/debug/Headroom --selftest` exit 0.
- **Do not modify** `AccountVault.swift`, `Keychain.swift`, `Store.swift`, `build.sh` (they carry an unrelated uncommitted fix). Edits to `PopoverView.swift` and `SelfTest.swift` must be purely additive (new lines/cases only).
- Spec: `docs/superpowers/specs/2026-08-19-spend-design.md`. UI copy: header **"Tokens"**, footnote **"est. API value $N · sticker rates as of {Pricing.asOf} · not billed spend"**.
- All test fixtures run under `HEADROOM_HOME` pointing at a temp dir (repo convention — never read live data in tests or renders).
- Match the repo's comment idiom: comments explain *why*, measured facts stated as measurements.
- Test helpers available in SelfTest.swift: `section("Name")`, `expect(Bool, "label")`.

---

### Task 1: `IndexerConfig` — make TranscriptIndexer configurable, defaults unchanged

**Files:**
- Modify: `Sources/Headroom/Core/TranscriptIndexer.swift`
- Test: `Sources/Headroom/SelfTest.swift` (new case `spendIndexerConfig()`, registered in `run()`)

**Interfaces:**
- Consumes: existing `TranscriptIndexer`, `IndexState`, `TokenUsage`, `ClaudePaths`.
- Produces: `struct IndexerConfig` with `bucketSeconds: TimeInterval`, `firstSightTailBytes: UInt64?`, `retention: TimeInterval?`, `persistentDedup: Bool`; statics `IndexerConfig.live` and `IndexerConfig.spend`; `TranscriptIndexer.init(root:stateURL:config:)` (config defaults to `.live`); instance methods `bucketIndex(_ date: Date) -> Int` and `bucketKey(_ date: Date, model: String) -> String` that use `config.bucketSeconds`. The existing `static bucketIndex/bucketKey` remain for existing callers (5-minute maths, unchanged).

- [ ] **Step 1: Write the failing test.** Append to SelfTest.swift (and add `spendIndexerConfig()` to `run()`):

```swift
private static func spendIndexerConfig() {
    section("Spend indexer config")

    // Live defaults must be byte-for-byte the constants the quota view was
    // tuned against -- this test is the regression tripwire for Task 1-4.
    let live = IndexerConfig.live
    expect(live.bucketSeconds == 300, "live buckets are 5 minutes")
    expect(live.firstSightTailBytes == 512 * 1024, "live first sight tails 512K")
    expect(live.retention == 14 * 24 * 3600, "live retention is 14 days")
    expect(live.persistentDedup == false, "live dedup is the 2h pending map")

    let spend = IndexerConfig.spend
    expect(spend.bucketSeconds == 3600, "spend buckets are hourly")
    expect(spend.firstSightTailBytes == nil, "spend backfills from byte 0")
    expect(spend.retention == nil, "spend never prunes")
    expect(spend.persistentDedup == true, "spend dedup is persistent")

    // Hour keys are epoch-based, i.e. inherently UTC.
    let indexer = TranscriptIndexer(
        root: URL(fileURLWithPath: "/nonexistent"),
        stateURL: URL(fileURLWithPath: "/tmp/never-written.json"),
        config: .spend)
    let date = Date(timeIntervalSince1970: 7200)  // 1970-01-01T02:00Z
    expect(indexer.bucketKey(date, model: "m") == "2:m", "hour bucket 2 for T02:00Z")
}
```

- [ ] **Step 2: Run to verify it fails.** `swift build 2>&1 | tail -5` — expected: compile error, `IndexerConfig` not found. (In this repo the "failing test" state for new API is the compile failure.)

- [ ] **Step 3: Implement.** In TranscriptIndexer.swift, above the class:

```swift
/// One indexer class, two jobs. The live quota view wants the last 14 days,
/// cheaply; the spend view wants all of history, exactly once. The difference
/// is entirely in these four knobs, so it is a config, not a subclass.
struct IndexerConfig: Equatable {
    /// Bucket width. 300 for the quota view; 3600 for spend history --
    /// hourly is fine-grained enough to regroup into local calendar days
    /// after a timezone change, and coarse enough to hold years of history.
    var bucketSeconds: TimeInterval = 300
    /// How much of a first-seen file to read, from the end. nil = from byte 0.
    var firstSightTailBytes: UInt64? = 512 * 1024
    /// Buckets older than this are dropped. nil = keep forever.
    var retention: TimeInterval? = 14 * 24 * 3600
    /// Remember every request identity across restarts (spend), rather than
    /// the 2-hour in-flight pending map (quota).
    var persistentDedup = false

    static let live = IndexerConfig()
    static let spend = IndexerConfig(
        bucketSeconds: 3600, firstSightTailBytes: nil,
        retention: nil, persistentDedup: true)
}
```

Inside the class: add `private let config: IndexerConfig`, change init to
`init(root: URL = ClaudePaths.projectsDir, stateURL: URL = ClaudePaths.support.appending(path: "index.json"), config: IndexerConfig = .live)`, store it. Add instance methods:

```swift
func bucketIndex(_ date: Date) -> Int {
    Int(date.timeIntervalSince1970 / config.bucketSeconds)
}
func bucketKey(_ date: Date, model: String) -> String {
    "\(bucketIndex(date)):\(model)"
}
```

Rewire the class's internal uses of `Self.bucketKey` / `Self.bucketIndex` (in `consume`, `prune`, `usage`) to the instance methods. Rewire `firstSightTailBytes` uses in `ingest` to `config.firstSightTailBytes` (nil → offset 0). Guard `prune` bucket-dropping with `if let retention = config.retention` (pending-map pruning stays unconditional). Keep the `static let bucketSeconds` and static `bucketIndex/bucketKey` untouched for outside callers.

- [ ] **Step 4: Verify.** `swift build 2>&1 | tail -3` clean; `.build/debug/Headroom --selftest` exit 0 with the new section passing. Then `rg -n "Self.bucketKey|Self.bucketIndex|firstSightTailBytes" Sources/Headroom/Core/TranscriptIndexer.swift` — no internal use of the statics remains except the static definitions themselves.

- [ ] **Step 5: Checkpoint.** `git diff --stat` shows only TranscriptIndexer.swift and SelfTest.swift changed. Do NOT commit.

---

### Task 2: Realpath dedup in file enumeration

**Files:**
- Modify: `Sources/Headroom/Core/TranscriptIndexer.swift` (`transcripts()`)
- Test: `Sources/Headroom/SelfTest.swift` (new case `spendSymlinkDedup()`)

**Interfaces:**
- Consumes: `transcripts()` (private).
- Produces: same signature; results canonicalized and unique. (Measured on this machine: 4 symlinked workflow dirs made 190 files enumerate twice.)

- [ ] **Step 1: Write the failing test.** The helper writes a fixture transcript and a symlinked directory that re-exposes it:

```swift
private static func spendSymlinkDedup() {
    section("Spend symlink dedup")

    let fm = FileManager.default
    let home = fm.temporaryDirectory.appending(path: "hr-symlink-\(UUID().uuidString)")
    let projects = home.appending(path: ".claude/projects/-Users-x")
    try? fm.createDirectory(at: projects.appending(path: "real"),
                            withIntermediateDirectories: true)

    // One assistant record, 100 output tokens.
    let line = """
    {"type":"assistant","requestId":"req_sym1","timestamp":"2026-08-10T12:00:00Z","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}

    """
    let file = projects.appending(path: "real/a.jsonl")
    try? line.data(using: .utf8)!.write(to: file)
    try? fm.createSymbolicLink(
        at: projects.appending(path: "alias"),
        withDestinationURL: projects.appending(path: "real"))

    let indexer = TranscriptIndexer(
        root: home.appending(path: ".claude/projects"),
        stateURL: home.appending(path: "spend-index.json"),
        config: .spend)
    indexer.refresh(now: Date(timeIntervalSince1970: 1_786_500_000))
    let all = indexer.total(since: .distantPast)
    expect(all.output == 100, "symlinked dir does not double count (got \(all.output))")
    try? fm.removeItem(at: home)
}
```

- [ ] **Step 2: Run to verify it fails.** Build + `--selftest`. Expected: `output == 200` (double count) → the expect FAILS. (If it passes accidentally because request-dedup absorbs it before Task 3 lands, the pending map only lives 2h from `now` — use one `now` for the refresh as shown so both copies are seen in one pass; the pending map *will* absorb same-requestId duplicates, so to make this test meaningful give the second... **no — keep it simple:** the enumeration-level dedup is what's under test. Temporarily assert on scan work instead: `expect(indexer.hasData, ...)` is too weak. Assert file-level: after refresh, the state must contain exactly one cursor. Add a query for it.)

  Replace the last two lines of Step 1's test with:

```swift
    indexer.refresh(now: Date(timeIntervalSince1970: 1_786_500_000))
    expect(indexer.cursorCount == 1, "one physical file, one cursor (got \(indexer.cursorCount))")
    expect(indexer.total(since: .distantPast).output == 100, "counted exactly once")
```

- [ ] **Step 3: Implement.** In `transcripts()`:

```swift
private func transcripts() -> [URL] {
    guard let walker = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.fileSizeKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    // Sessions symlink each other's workflow dirs, so a naive walk lists the
    // same physical file more than once (measured: 190 of 2,764 on this
    // machine). Request dedup would absorb the double count, but only by
    // reading every duplicated byte twice -- canonicalize and unique instead.
    var seen = Set<String>()
    var out: [URL] = []
    for case let url as URL in walker where url.pathExtension == "jsonl" {
        let real = url.resolvingSymlinksInPath()
        if seen.insert(real.path).inserted { out.append(real) }
    }
    return out
}
```

And the tiny query used by the test:

```swift
/// Fixture visibility only: how many physical files the index tracks.
var cursorCount: Int {
    lock.lock(); defer { lock.unlock() }
    load()
    return state.cursors.count
}
```

- [ ] **Step 4: Verify.** Build clean, selftest exit 0, new section passes.
- [ ] **Step 5: Checkpoint.** `git diff --stat` — same two files only. No commit.

---

### Task 3: Persistent, bounded request dedup + fallback identity

**Files:**
- Modify: `Sources/Headroom/Core/TranscriptIndexer.swift` (`IndexState`, `consume`, `ingest`, `prune`)
- Test: `Sources/Headroom/SelfTest.swift` (new case `spendDedup()`)

**Interfaces:**
- Consumes: Task 1's `config.persistentDedup`.
- Produces: `IndexState.seen: [String: Int]?` (FNV-1a 64-bit hash, lowercase hex, → epoch-day last seen; optional so pre-existing live state files decode unchanged — that optionality IS the migration). `consume(_ line: Data, at offset: UInt64, in filePath: String, now: Date)` — new signature, internal only. Constants `seenCap = 500_000`, `seenEvictionDays = 90`.

- [ ] **Step 1: Write the failing test:**

```swift
private static func spendDedup() {
    section("Spend dedup")

    let fm = FileManager.default
    let home = fm.temporaryDirectory.appending(path: "hr-dedup-\(UUID().uuidString)")
    let projects = home.appending(path: ".claude/projects/-Users-x")
    try? fm.createDirectory(at: projects, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 1_786_500_000)

    func record(_ rid: String?, msgID: String? = nil, out: Int) -> String {
        let ridField = rid.map { "\"requestId\":\"\($0)\"," } ?? ""
        let idField = msgID.map { "\"id\":\"\($0)\"," } ?? ""
        return """
        {"type":"assistant",\(ridField)"timestamp":"2026-08-10T12:00:00Z","message":{\(idField)"model":"claude-opus-5","usage":{"input_tokens":5,"output_tokens":\(out),"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
        """
    }

    // File A: one request streamed as three growing iterations, plus a
    // record with no requestId (falls back to message.id), plus a record
    // with neither (falls back to file+offset identity).
    let a = [record("req_1", out: 10), record("req_1", out: 25), record("req_1", out: 40),
             record(nil, msgID: "msg_1", out: 7), record(nil, out: 3)]
        .joined(separator: "\n") + "\n"
    // File B: a physical copy of req_1's final iteration (a forked session).
    let b = record("req_1", out: 40) + "\n"
    try? a.data(using: .utf8)!.write(to: projects.appending(path: "a.jsonl"))
    try? b.data(using: .utf8)!.write(to: projects.appending(path: "b.jsonl"))

    let stateURL = home.appending(path: "spend-index.json")
    let indexer = TranscriptIndexer(
        root: home.appending(path: ".claude/projects"), stateURL: stateURL, config: .spend)
    indexer.refresh(now: now)
    expect(indexer.total(since: .distantPast).output == 50,
           "streamed req counts once at final output; fallbacks count once each (got \(indexer.total(since: .distantPast).output))")

    // Shrink-and-rescan: rewrite file B from scratch with the same content.
    // The persistent seen-set must absorb the rescan across a NEW instance
    // (fresh pending map) -- this is what the in-memory map cannot do.
    try? (b + b).data(using: .utf8)!.write(to: projects.appending(path: "b.jsonl"))
    try? b.data(using: .utf8)!.write(to: projects.appending(path: "b.jsonl"))
    let again = TranscriptIndexer(
        root: home.appending(path: ".claude/projects"), stateURL: stateURL, config: .spend)
    again.refresh(now: now.addingTimeInterval(3 * 3600))
    expect(again.total(since: .distantPast).output == 50,
           "rescan after shrink adds nothing (got \(again.total(since: .distantPast).output))")
    try? fm.removeItem(at: home)
}
```

- [ ] **Step 2: Run to verify it fails.** Expected failures: output 90 on the first expect (req_1 in file B double counts once the 2h pending map is the only guard *across instances*... it actually catches it within one instance; the decisive failure is the second expect: fresh instance, rescan double counts → 90).

- [ ] **Step 3: Implement.**

`IndexState` gains one field (optional → old files decode as nil):

```swift
struct IndexState: Codable {
    var version: Int = 1
    var cursors: [String: Cursor] = [:]
    var buckets: [String: TokenUsage] = [:]
    var pending: [String: PendingRequest] = [:]
    /// Persistent request-identity dedup (spend config only): FNV-1a 64 hash,
    /// hex, -> epoch day last seen. Cross-file duplicates come from forks and
    /// symlinked copies written in the same period, so a 90-day horizon is a
    /// safe eviction bound once the set passes 500k (~ single-digit MB).
    var seen: [String: Int]? = nil
}
```

Hash + identity helpers in the class:

```swift
private static func fnv1a(_ s: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return String(h, radix: 16)
}
```

`ingest` passes each line's absolute offset: it already computes `start` and `cursor.offset`; collect `(Data, UInt64)` pairs — `lineData.append((Data(...), cursor.offset + UInt64(start)))` — and call `consume(line, at: off, in: path, now: now)`.

`consume` changes (only when `config.persistentDedup`; the live path is untouched — `requestId` remains required there exactly as today):

```swift
// Identity: requestId, else message id, else where the bytes live. Every
// usage-bearing record gets exactly one identity, so nothing billable is
// dropped and nothing is counted twice. (Measured 2026-08-19: 0 of 150,493
// records on this machine lack both ids -- the offset form is a backstop.)
let identity = object["requestId"] as? String
    ?? message["id"] as? String
    ?? "\(filePath)#\(offset)"
```

Dedup gate, after the existing pending-map handling (which still owns the within-2h output-growth correction; `identity` replaces `requestID` as the pending key in spend mode):

```swift
if config.persistentDedup {
    let key = Self.fnv1a(identity)
    let day = Int(timestamp.timeIntervalSince1970 / 86_400)
    if state.pending[identity] == nil, state.seen?[key] != nil {
        return TokenUsage()  // re-seen in a rescan or a forked copy
    }
    state.seen = state.seen ?? [:]
    state.seen?[key] = max(state.seen?[key] ?? 0, day)
}
```

Eviction in `prune` (spend mode only):

```swift
if config.persistentDedup, let seen = state.seen, seen.count > Self.seenCap {
    let horizon = Int(now.timeIntervalSince1970 / 86_400) - Self.seenEvictionDays
    state.seen = seen.filter { $0.value >= horizon }
}
```

with `private static let seenCap = 500_000` and `private static let seenEvictionDays = 90`.

- [ ] **Step 4: Verify.** Build clean; selftest exit 0; both new expects pass. Also confirm migration: decode an old-format state JSON (write `{"version":1,"cursors":{},"buckets":{},"pending":{}}` to a temp file, construct an indexer on it, `expect(indexer.hasData == false, "pre-seen state file loads")`) — add this expect to the same case.
- [ ] **Step 5: Checkpoint.** Diff limited to the two files. No commit.

---

### Task 4: Backfill scanning — chunked, budgeted, resumable

**Files:**
- Modify: `Sources/Headroom/Core/TranscriptIndexer.swift` (`refresh`, `ingest`)
- Test: `Sources/Headroom/SelfTest.swift` (new case `spendBackfill()`)

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `refresh(now:budget:)` — `budget: TimeInterval? = nil`; when set, the scan stops cleanly between files once exceeded (state saved, resumable). `var backfillProgress: (done: Int, total: Int)` — files fully caught up vs files known. Chunked reads: 4 MB per read instead of `readToEnd`, state saved after each file in spend mode.

- [ ] **Step 1: Write the failing test:**

```swift
private static func spendBackfill() {
    section("Spend backfill")

    let fm = FileManager.default
    let home = fm.temporaryDirectory.appending(path: "hr-backfill-\(UUID().uuidString)")
    let projects = home.appending(path: ".claude/projects/-Users-x")
    try? fm.createDirectory(at: projects, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 1_786_500_000)

    // Three files, one record each, 100 output tokens apiece. A corrupted
    // line and a synthetic record ride along and must be ignored.
    for i in 0..<3 {
        let good = """
        {"type":"assistant","requestId":"req_b\(i)","timestamp":"2026-08-10T0\(i):30:00Z","message":{"model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
        """
        let junk = "{\"type\":\"assistant\",\"requestId\":\"req_junk\(i)\",TRUNCATED GARBAGE"
        let synth = """
        {"type":"assistant","requestId":"req_s\(i)","timestamp":"2026-08-10T0\(i):31:00Z","message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0}}}
        """
        try? [good, junk, synth].joined(separator: "\n").appending("\n")
            .data(using: .utf8)!.write(to: projects.appending(path: "f\(i).jsonl"))
    }

    let stateURL = home.appending(path: "spend-index.json")
    let a = TranscriptIndexer(root: home.appending(path: ".claude/projects"),
                              stateURL: stateURL, config: .spend)
    // A zero budget still makes progress: at least one file per call, never a
    // stall. Three calls finish three files.
    a.refresh(now: now, budget: 0)
    let p = a.backfillProgress
    expect(p.done >= 1 && p.done < 3, "zero budget does one file, not all (done=\(p.done))")

    // A fresh instance resumes from persisted offsets -- nothing recounted.
    let b = TranscriptIndexer(root: home.appending(path: ".claude/projects"),
                              stateURL: stateURL, config: .spend)
    b.refresh(now: now)
    expect(b.backfillProgress.done == 3, "resume completes all files")
    expect(b.total(since: .distantPast).output == 300,
           "3 good records, junk and synthetic ignored (got \(b.total(since: .distantPast).output))")
    try? fm.removeItem(at: home)
}
```

Note the synthetic record contributes zero even if parsed (measured: all-zero usage on every `<synthetic>` record on this machine); the model gate below makes it explicit.

- [ ] **Step 2: Run to verify it fails.** Compile error: no `budget:` parameter / `backfillProgress`.

- [ ] **Step 3: Implement.**

In `refresh`, add the budget and per-file save:

```swift
@discardableResult
func refresh(now: Date = Date(), budget: TimeInterval? = nil) -> TokenUsage {
    lock.lock()
    defer { lock.unlock() }
    load()

    var added = TokenUsage()
    let files = transcripts()
    knownFiles = files.count
    let started = Date()
    for file in files {
        added += ingest(file, now: now)
        if config.persistentDedup { save() }  // durable per file: quit-safe
        // Budget is checked between files so a call always advances at least
        // one file -- a stall would otherwise be invisible to the caller.
        if let budget, Date().timeIntervalSince(started) > budget { break }
    }
    prune(now: now)
    save()
    return added
}
```

Progress (add `private var knownFiles = 0`):

```swift
/// Files fully caught up vs files known -- drives "scanning history… N%".
var backfillProgress: (done: Int, total: Int) {
    lock.lock(); defer { lock.unlock() }
    load()
    let done = state.cursors.values.filter { $0.offset >= $0.size }.count
    return (done, max(knownFiles, state.cursors.count))
}
```

In `ingest`, replace the single `readToEnd` with a 4 MB chunk loop (keeps peak memory flat on the 27 MB worst-case transcript; the existing pointer-scan per chunk is unchanged — carry the trailing partial line's bytes into the next chunk, or simpler: stop each chunk at its last newline via `consumedBytes` exactly as the code already does and seek there for the next chunk):

```swift
let chunkSize = 4 * 1024 * 1024
var readFrom = cursor.offset
while readFrom < size {
    try? handle.seek(toOffset: readFrom)
    guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
    // ... existing withUnsafeBytes scan over `chunk`, producing lineData
    //     entries as (Data, absoluteOffset) and consumedBytes ...
    if consumedBytes == 0 { break }  // a >4MB line: give up on the file tail
    readFrom += UInt64(consumedBytes)
}
state.cursors[path] = Cursor(offset: readFrom, size: size)
```

In `consume`, gate the model (spend mode counts nothing for synthetic records; harmless for live mode too since their usage is all-zero):

```swift
let model = message["model"] as? String ?? "unknown"
guard model != "<synthetic>" else { return TokenUsage() }
```

The existing `try? JSONSerialization...else { return TokenUsage() }` already makes corrupted lines a silent skip; add a `Diag.log` counter increment so `--selftest` diagnostics can surface it.

- [ ] **Step 4: Verify.** Build clean, selftest exit 0, all three expects pass. Re-run the full selftest twice in a row — second run must also pass (idempotent fixtures).
- [ ] **Step 5: Checkpoint.** Diff limited to the two files. No commit.

---

### Task 5: Spend snapshot — calendar grouping, pricing provenance, rounding

**Files:**
- Create: `Sources/Headroom/Core/Spend.swift`
- Modify: `Sources/Headroom/Core/Pricing.swift` (add one constant)
- Test: `Sources/Headroom/SelfTest.swift` (new case `spendSnapshot()`)

**Interfaces:**
- Consumes: `TranscriptIndexer.usageByBucket()` (new query added here), `Pricing.cost(_:model:)`, `TokenUsage`.
- Produces:

```swift
struct SpendSnapshot {
    let today: TokenUsage
    let month: TokenUsage
    let allTime: TokenUsage
    let perModel: [(model: String, usage: TokenUsage)]  // sorted by total desc
    let estimatedValue: Double   // dollars at sticker rates, all time
    let unpricedModels: [String]
}
enum Spend {
    static func snapshot(buckets: [String: TokenUsage],
                         bucketSeconds: TimeInterval,
                         calendar: Calendar = .current,
                         now: Date = Date()) -> SpendSnapshot
    static func format(tokens: Int) -> String   // "9.04 B", "512 M", "68.2 M", "1,241"
    static func format(dollars: Double) -> String  // cents < $100, whole $ above, half away from zero
}
```

plus `Pricing.asOf = "2026-08"` and `TranscriptIndexer.usageByBucket() -> [String: TokenUsage]` (a locked copy of `state.buckets`).

- [ ] **Step 1: Write the failing test:**

```swift
private static func spendSnapshot() {
    section("Spend snapshot")

    // Fixed zone so the test is deterministic on any machine.
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

    // 2026-08-19 10:00 PT == 17:00 UTC. Hour buckets are UTC-epoch indexed.
    let now = Date(timeIntervalSince1970: 1_787_504_400)
    func hourKey(_ epoch: TimeInterval, _ model: String) -> String {
        "\(Int(epoch / 3600)):\(model)"
    }
    var u1 = TokenUsage(); u1.output = 1_000_000            // today, 09:00 PT
    var u2 = TokenUsage(); u2.output = 2_000_000            // this month, Aug 1 PT
    var u3 = TokenUsage(); u3.cacheRead = 10_000_000        // July 31 23:00 PT -> last month
    let buckets = [
        hourKey(1_787_500_800, "claude-opus-5"): u1,
        hourKey(1_785_925_200, "claude-opus-5"): u2,   // 2026-08-01 06:00Z = Jul 31 23:00 PT? — pick 2026-08-01 12:00Z to stay unambiguous
        hourKey(1_785_596_400, "claude-sonnet-5"): u3, // 2026-07-28 12:00Z, prior month
    ]
    let snap = Spend.snapshot(buckets: buckets, bucketSeconds: 3600, calendar: cal, now: now)
    expect(snap.today.output == 1_000_000, "today is the local calendar day")
    expect(snap.month.output == 3_000_000, "month is the local calendar month")
    expect(snap.allTime.total == 13_000_000, "all time sums everything")
    expect(snap.perModel.first?.model == "claude-sonnet-5", "sorted by tokens moved")
    // 3M output opus-5 at $25/M + 10M cache read sonnet-5 at $0.30/M = 75 + 3.
    expect(abs(snap.estimatedValue - 78.0) < 0.005, "dollars within half a cent")

    expect(Spend.format(tokens: 9_043_823_770) == "9.04 B", "billions, two decimals")
    expect(Spend.format(tokens: 512_000_000) == "512 M", "round millions")
    expect(Spend.format(tokens: 1_241) == "1,241", "small counts verbatim")
    expect(Spend.format(dollars: 7423.82) == "$7,424", "whole dollars at >= $100")
    expect(Spend.format(dollars: 99.994) == "$99.99", "cents below $100")
}
```

(Before finalizing the fixture epochs, verify each with `TZ=UTC date -r <epoch>` and pick values ≥ 1 hour clear of the month boundary in both zones — the intent is one bucket firmly in July PT.)

- [ ] **Step 2: Run to verify it fails.** Compile error: `Spend` not found.

- [ ] **Step 3: Implement `Spend.swift`.**

```swift
import Foundation

/// Render-side rollup of the spend indexer's hour buckets. Storage is tokens;
/// dollars exist only here, so a Pricing table update reprices all history.
struct SpendSnapshot { /* fields as in Interfaces */ }

enum Spend {
    static func snapshot(buckets: [String: TokenUsage],
                         bucketSeconds: TimeInterval,
                         calendar: Calendar = .current,
                         now: Date = Date()) -> SpendSnapshot {
        var today = TokenUsage(), month = TokenUsage(), all = TokenUsage()
        var perModel: [String: TokenUsage] = [:]
        let dayStart = calendar.startOfDay(for: now)
        let monthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: now)) ?? dayStart

        for (key, usage) in buckets {
            let parts = key.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let index = Int(parts[0]) else { continue }
            // Buckets are UTC-epoch indexed; grouping into local days happens
            // here, at render, with whatever timezone the Mac has *now* --
            // hourly storage is finer than any display period, so a timezone
            // change regroups history correctly with no stored rebucketing.
            let ts = Date(timeIntervalSince1970: Double(index) * bucketSeconds)
            let model = String(parts[1])
            all += usage
            perModel[model, default: TokenUsage()] += usage
            if ts >= dayStart { today += usage }
            if ts >= monthStart { month += usage }
        }

        var value = 0.0
        var unpriced: [String] = []
        for (model, usage) in perModel {
            if let cost = Pricing.cost(usage, model: model) { value += cost }
            else { unpriced.append(model) }
        }
        return SpendSnapshot(
            today: today, month: month, allTime: all,
            perModel: perModel.sorted { $0.value.total > $1.value.total }
                .map { (model: $0.key, usage: $0.value) },
            estimatedValue: value, unpricedModels: unpriced.sorted())
    }

    static func format(tokens: Int) -> String {
        let t = Double(tokens)
        switch t {
        case 1e9...: return trim(t / 1e9, unit: "B")
        case 1e6...: return trim(t / 1e6, unit: "M")
        default:
            let f = NumberFormatter(); f.numberStyle = .decimal
            return f.string(from: NSNumber(value: tokens)) ?? "\(tokens)"
        }
    }

    /// 3 significant-ish digits: 9.04 B, 68.2 M, 512 M.
    private static func trim(_ v: Double, unit: String) -> String {
        let s: String
        if v >= 100 { s = String(format: "%.0f", v) }
        else if v >= 10 { s = String(format: "%.1f", v) }
        else { s = String(format: "%.2f", v) }
        return "\(s) \(unit)"
    }

    /// One rounding, at display: half away from zero. Cents under $100,
    /// whole dollars at or above -- a menu bar number, not an invoice.
    static func format(dollars: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency; f.currencyCode = "USD"
        f.roundingMode = .halfUp
        f.maximumFractionDigits = dollars.magnitude >= 100 ? 0 : 2
        f.minimumFractionDigits = f.maximumFractionDigits
        return f.string(from: NSNumber(value: dollars)) ?? "$\(dollars)"
    }
}
```

In `Pricing.swift`, add (comment idiom matched to the file):

```swift
/// When the table above was last verified against published rates. Shown in
/// the UI footnote -- the provenance for every dollar figure Headroom renders.
static let asOf = "2026-08"
```

In `TranscriptIndexer`, the query:

```swift
/// Snapshot of every bucket, for render-side grouping the 14-day-window
/// queries above cannot express (all-time, calendar months).
func usageByBucket() -> [String: TokenUsage] {
    lock.lock(); defer { lock.unlock() }
    load()
    return state.buckets
}
```

- [ ] **Step 4: Verify.** Build clean, selftest exit 0, all expects pass.
- [ ] **Step 5: Checkpoint.** Diff: Spend.swift (new), Pricing.swift (+3 lines), TranscriptIndexer.swift (+query), SelfTest.swift (additive). No commit.

---

### Task 6: UI — SpendSection in the popover + app wiring

**Files:**
- Create: `Sources/Headroom/UI/SpendSection.swift`
- Modify: `Sources/Headroom/UI/PopoverView.swift` (one insertion), `Sources/Headroom/UI/AppDelegate.swift` (spend indexer instance + background refresh)
- Test: manual render against a fixture (`HEADROOM_HOME`), never live data

**Interfaces:**
- Consumes: `Spend.snapshot`, `TranscriptIndexer(root:stateURL:config:)`, `backfillProgress`, existing `Theme` styles (copy the fonts/spacing used by the adjacent sections in PopoverView — match, don't invent).
- Produces: `SpendSection(snapshot: SpendSnapshot, progress: (done: Int, total: Int))` SwiftUI view; `AppDelegate.spendIndexer` on state file `ClaudePaths.support.appending(path: "spend-index.json")`.

- [ ] **Step 1: Build the view.** Follow the visual grammar of the existing sections (read the neighboring section in PopoverView first; reuse `Theme.body`, the same Divider treatment, aligned trailing numerals):

```swift
/// Token totals, all accounts (= this Mac). Tokens lead; the one dollar
/// figure is a footnote -- "I don't care about money. I just care about
/// tokens." (Angus, 2026-08-19.)
struct SpendSection: View {
    let snapshot: SpendSnapshot
    let progress: (done: Int, total: Int)
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s1) {
            row("Today", snapshot.today)
            row("This month", snapshot.month)
            row("All time", snapshot.allTime)
            if progress.done < progress.total {
                Text("scanning history… \(progress.total == 0 ? 0 : progress.done * 100 / progress.total)%")
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("per model", isExpanded: $expanded) {
                ForEach(snapshot.perModel, id: \.model) { entry in
                    row(shortName(entry.model), entry.usage)
                }
            }
            Text("est. API value \(Spend.format(dollars: snapshot.estimatedValue)) · sticker rates as of \(Pricing.asOf) · not billed spend")
                .font(Theme.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ label: String, _ usage: TokenUsage) -> some View {
        HStack {
            Text(label).font(Theme.body)
            Spacer()
            Text(Spend.format(tokens: usage.total))
                .font(Theme.body.weight(.medium)).monospacedDigit()
        }
    }

    /// "claude-opus-5" -> "Opus 5" -- the popover column is narrow.
    private func shortName(_ id: String) -> String {
        id.replacingOccurrences(of: "claude-", with: "")
          .split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
          .joined(separator: " ")
    }
}
```

(Adjust `Theme.caption` to whatever the file actually names its small style — check `Theme.swift` before writing; if there is no caption style, use the smallest one the popover already uses.)

- [ ] **Step 2: Wire it.** In AppDelegate: a `let spendIndexer = TranscriptIndexer(stateURL: ClaudePaths.support.appending(path: "spend-index.json"), config: .spend)` and, wherever the live indexer is refreshed today, add a `.utility`-QoS dispatch that calls `spendIndexer.refresh(budget: 2.0)` repeatedly (rescheduling itself while `backfillProgress.done < total`, then settling to the same cadence as the live refresh). The budget slices are the throttle and the natural cancellation point — app quit simply stops rescheduling; state is durable per file (Task 4).

  In PopoverView, insert `SpendSection(snapshot:progress:)` after the existing usage section with the same `Divider()` treatment the file uses between sections. The snapshot is computed at render: `Spend.snapshot(buckets: spendIndexer.usageByBucket(), bucketSeconds: 3600)`.

- [ ] **Step 3: Verify visually.** `swift build` clean; render screenshots only with `HEADROOM_HOME=<fixture>` (repo rule: plain `--render` leaks real account addresses). Build a small fixture with two models across two days and eyeball: header "Tokens", three rows, disclosure, footnote.

- [ ] **Step 4: Full selftest.** `.build/debug/Headroom --selftest` exit 0. (The count is data-dependent by design — do not assert on the total number of checks.)

- [ ] **Step 5: Checkpoint.** `git diff --stat` shows: TranscriptIndexer.swift, Pricing.swift, Spend.swift, SpendSection.swift, PopoverView.swift (additive), AppDelegate.swift, SelfTest.swift (additive), plus the two docs. **Nothing from the Keychain/swap fix set beyond what was already dirty, and no commits.**

---

### Task 7: Regression sweep — the live indexer is provably unchanged

**Files:**
- Test: `Sources/Headroom/SelfTest.swift` (new case `liveIndexerRegression()`)

**Interfaces:**
- Consumes: default-config `TranscriptIndexer` (no `config:` argument at any existing call site — verify with `rg -n "TranscriptIndexer(" Sources | rg -v config`).

- [ ] **Step 1: Write the test** — a fixture proving the default config still: tails 512K on first sight, 5-minute buckets, 14-day prune, requestId-required consume:

```swift
private static func liveIndexerRegression() {
    section("Live indexer regression")

    let fm = FileManager.default
    let home = fm.temporaryDirectory.appending(path: "hr-live-\(UUID().uuidString)")
    let projects = home.appending(path: ".claude/projects/-Users-x")
    try? fm.createDirectory(at: projects, withIntermediateDirectories: true)
    let now = Date()
    let ts = ISO8601DateFormatter().string(from: now)

    // Padding puts an old record beyond the 512K first-sight tail: the live
    // config must NOT see it; the spend config (Task 4 test) does.
    let old = "{\"type\":\"assistant\",\"requestId\":\"req_old\",\"timestamp\":\"\(ts)\",\"message\":{\"model\":\"m\",\"usage\":{\"input_tokens\":0,\"output_tokens\":999,\"cache_read_input_tokens\":0}}}\n"
    let pad = String(repeating: "{\"type\":\"padding\"}\n", count: 40_000)  // ~800KB
    let fresh = "{\"type\":\"assistant\",\"requestId\":\"req_new\",\"timestamp\":\"\(ts)\",\"message\":{\"model\":\"m\",\"usage\":{\"input_tokens\":0,\"output_tokens\":111,\"cache_read_input_tokens\":0}}}\n"
    try? (old + pad + fresh).data(using: .utf8)!
        .write(to: projects.appending(path: "live.jsonl"))

    let indexer = TranscriptIndexer(
        root: home.appending(path: ".claude/projects"),
        stateURL: home.appending(path: "index.json"))  // default .live config
    indexer.refresh(now: now)
    let total = indexer.total(since: now.addingTimeInterval(-3600), now: now)
    expect(total.output == 111, "first sight still tails 512K -- old record invisible (got \(total.output))")
    expect(indexer.bucketKey(now, model: "m") == TranscriptIndexer.bucketKey(now, model: "m"),
           "instance and static bucket keys agree on the live config")
    try? fm.removeItem(at: home)
}
```

- [ ] **Step 2: Run** — must pass immediately if Tasks 1–4 preserved defaults; a failure here is a Task 1–4 bug, fix there, not here.
- [ ] **Step 3: Full sweep.** `swift build 2>&1 | tail -3` clean; `.build/debug/Headroom --selftest` exit 0; run twice.
- [ ] **Step 4: Final checkpoint.** `git status --short` — confirm the pre-existing dirty files are exactly as they were (`git diff --stat Sources/Headroom/Core/AccountVault.swift Sources/Headroom/Core/Keychain.swift Sources/Headroom/Core/Store.swift build.sh` matches its state before Task 1). No commit, no install.

---

## Self-review notes

- Spec coverage: tokens-first UI (T6), isolated backfill state via separate state file + per-file durable saves (T3/T4), persistent bounded dedup + fallback identities + symlink/canonical test (T2/T3), UTC-hour storage + current-TZ render grouping (T5), cancellation/throttle via budget slices (T4/T6), corrupted/truncated handling (T4), pricing provenance `Pricing.asOf` (T5), cent rounding (T5), migration + live-indexer regression (T3 step 4, T7). Slice 2 (per-account attribution) deliberately absent, per spec.
- Type consistency: `IndexerConfig.spend`, `usageByBucket()`, `backfillProgress`, `Spend.snapshot/format`, `SpendSnapshot` — names match across tasks.
- The one deviation from the writing-plans template: no commit steps, by explicit standing instruction.
