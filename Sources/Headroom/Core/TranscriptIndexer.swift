import Foundation

struct TokenUsage: Codable, Equatable, Sendable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite5m: Int = 0
    var cacheWrite1h: Int = 0

    /// What the window actually charges against. Cache reads are billed at a
    /// fraction of input, so a raw sum is the wrong headline number -- but for
    /// "how much did I move" it is the honest total.
    var total: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }

    static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheRead += rhs.cacheRead
        lhs.cacheWrite5m += rhs.cacheWrite5m
        lhs.cacheWrite1h += rhs.cacheWrite1h
    }
}

/// Where a file was last read to. Size is kept so truncation or rotation is
/// detectable -- a file that shrank is a different file.
struct Cursor: Codable, Equatable {
    var offset: UInt64
    var size: UInt64
}

/// A request whose records may still be arriving.
///
/// Claude Code writes one `assistant` record per streaming iteration, all
/// sharing a `requestId`, and `output_tokens` grows across them while the input
/// and cache figures stay fixed. Measured on real transcripts: 104 assistant
/// records for 41 actual requests, and across 35 duplicated ids the last record
/// always carried the largest output. So the rule is last-wins on output.
///
/// The iterations can straddle a cursor boundary -- partial record this poll,
/// final record the next -- so what was already added to a bucket is remembered
/// here and corrected by delta when a bigger output arrives.
struct PendingRequest: Codable, Equatable {
    var bucket: String
    var output: Int
    var lastSeen: Date
}

struct IndexState: Codable {
    var version: Int = 1
    var cursors: [String: Cursor] = [:]
    /// Key is "<bucketIndex>:<model>", so cost can be resolved per model.
    var buckets: [String: TokenUsage] = [:]
    var pending: [String: PendingRequest] = [:]
}

/// Tails `~/.claude/projects/**/*.jsonl` to build a token history.
///
/// Constraints that shaped this, all measured rather than assumed:
/// 642 MB across 504 files, 489 of them touched within the last day, and the
/// largest single transcript is 27 MB. Nothing here may read a whole file, and
/// filtering by mtime buys nothing on a machine this busy. So: persistent
/// per-file byte cursors, and a first-sight cap that starts each new file near
/// its end instead of backfilling all of history (that is what `stats-cache.json`
/// is for -- Claude Code has already aggregated the past).
/// Deliberately a lock-guarded class rather than an `actor`.
///
/// This binary links AppKit, which makes the main run loop the default executor
/// for a top-level `Task`. Any synchronous entry point that blocks main while
/// awaiting one -- the `--probe` command line path, for instance -- then hangs
/// forever with the task never scheduled: a stack sample shows a single thread
/// parked in `semaphore_wait_trap`. Keeping the indexer synchronous means the
/// CLI can call it directly and the GUI can dispatch it to a background queue,
/// with neither having to reason about executors.
final class TranscriptIndexer: @unchecked Sendable {
    private let lock = NSLock()

    static let bucketSeconds: TimeInterval = 300

    /// How far back to start when a file is seen for the first time. Bounds a
    /// cold start to roughly 50 MB rather than 642 MB.
    private static let firstSightTailBytes: UInt64 = 512 * 1024

    /// Requests stop being correctable once they are this old.
    private static let pendingTTL: TimeInterval = 2 * 3600

    /// Buckets older than this are dropped; the panel never looks further back.
    private static let retention: TimeInterval = 14 * 24 * 3600

    private let root: URL
    private let stateURL: URL
    private var state = IndexState()
    private var loaded = false

    init(root: URL = ClaudePaths.projectsDir,
         stateURL: URL = ClaudePaths.support.appending(path: "index.json")) {
        self.root = root
        self.stateURL = stateURL
    }

    // MARK: State

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = FileManager.default.contents(atPath: stateURL.path),
              let decoded = try? JSONDecoder().decode(IndexState.self, from: data)
        else { return }
        state = decoded
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    // MARK: Scanning

    @discardableResult
    func refresh(now: Date = Date()) -> TokenUsage {
        lock.lock()
        defer { lock.unlock() }
        load()

        var added = TokenUsage()
        let files = transcripts()
        Diag.log("indexer: \(files.count) files")
        var n = 0
        for file in files {
            let t0 = Date()
            added += ingest(file, now: now)
            let dt = Date().timeIntervalSince(t0)
            n += 1
            if dt > 0.5 { Diag.log("indexer: SLOW \(String(format: "%.1f", dt))s \(file.lastPathComponent)") }
            if n % 100 == 0 { Diag.log("indexer: \(n)/\(files.count)") }
        }
        Diag.log("indexer: scanned, pruning")

        prune(now: now)
        Diag.log("indexer: pruned, saving (\(state.buckets.count) buckets, \(state.pending.count) pending)")
        save()
        Diag.log("indexer: saved")
        return added
    }

    private func transcripts() -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    private func ingest(_ url: URL, now: Date) -> TokenUsage {
        let path = url.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              size > 0
        else { return TokenUsage() }

        let isFirstSight = state.cursors[path] == nil
        var cursor = state.cursors[path] ?? Cursor(
            // First sight: skip to near the end rather than reading history.
            offset: size > Self.firstSightTailBytes ? size - Self.firstSightTailBytes : 0,
            size: 0
        )

        // Truncated or replaced: the offset no longer means anything.
        if size < cursor.size { cursor.offset = 0 }
        guard size > cursor.offset else {
            state.cursors[path] = Cursor(offset: cursor.offset, size: size)
            return TokenUsage()
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return TokenUsage() }
        defer { try? handle.close() }

        try? handle.seek(toOffset: cursor.offset)
        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else {
            state.cursors[path] = Cursor(offset: cursor.offset, size: size)
            return TokenUsage()
        }

        // Split over a raw pointer rather than with `Data.split`.
        //
        // This is the whole performance story. `Data`'s Collection conformance
        // goes through bounds and region checks on every byte, so splitting a
        // 512 KB chunk and materialising each line as its own `Data` turns a
        // ~200 MB cold start into minutes even in a release build. Scanning the
        // buffer directly means a line that is not an `assistant` record costs a
        // memchr and nothing else -- and the overwhelming majority are not.
        var added = TokenUsage()
        var consumedBytes = 0
        var lineData: [Data] = []

        chunk.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let newline = UInt8(ascii: "\n")
            var start = 0
            var isLeadingFragment = isFirstSight && cursor.offset > 0

            for i in 0..<buffer.count where base[i] == newline {
                defer { start = i + 1 }
                consumedBytes = i + 1

                // A first-sight offset is a raw byte count landing mid-line, so
                // the leading fragment is not valid JSON. Every later poll starts
                // exactly after a newline and drops nothing.
                if isLeadingFragment {
                    isLeadingFragment = false
                    continue
                }

                let length = i - start
                guard length > 40,
                      Self.hasAssistantMarker(base + start, length)
                else { continue }

                lineData.append(Data(bytes: base + start, count: length))
            }
        }

        for line in lineData {
            added += consume(line, now: now)
        }

        state.cursors[path] = Cursor(
            offset: cursor.offset + UInt64(consumedBytes),
            size: size
        )
        return added
    }

    /// Raw-pointer substring search for the one record type that carries usage.
    private static func hasAssistantMarker(_ base: UnsafePointer<UInt8>, _ length: Int) -> Bool {
        let needle = assistantMarker
        guard length >= needle.count else { return false }
        let limit = length - needle.count
        var i = 0
        while i <= limit {
            if base[i] == needle[0] {
                var j = 1
                while j < needle.count && base[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    /// Marker used to skip lines without paying for a JSON parse. Most records
    /// in a transcript are user turns, file snapshots, and queue operations --
    /// only `assistant` records carry usage.
    private static let assistantMarker = Array("\"type\":\"assistant\"".utf8)

    /// Callers have already confirmed the line is an assistant record.
    private func consume(_ line: Data, now: Date) -> TokenUsage {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "assistant",
              let requestID = object["requestId"] as? String,
              let message = object["message"] as? [String: Any],
              let raw = message["usage"] as? [String: Any]
        else { return TokenUsage() }

        let model = message["model"] as? String ?? "unknown"
        let timestamp = (object["timestamp"] as? String)
            .flatMap(QuotaReader.parseTimestamp) ?? now

        let creation = raw["cache_creation"] as? [String: Any]
        var usage = TokenUsage(
            input: raw["input_tokens"] as? Int ?? 0,
            output: raw["output_tokens"] as? Int ?? 0,
            cacheRead: raw["cache_read_input_tokens"] as? Int ?? 0,
            cacheWrite5m: creation?["ephemeral_5m_input_tokens"] as? Int ?? 0,
            cacheWrite1h: creation?["ephemeral_1h_input_tokens"] as? Int ?? 0
        )

        // Fall back to the flat field when the split is absent, so cache writes
        // are never silently dropped.
        if usage.cacheWrite5m == 0 && usage.cacheWrite1h == 0 {
            usage.cacheWrite5m = raw["cache_creation_input_tokens"] as? Int ?? 0
        }

        let bucket = Self.bucketKey(timestamp, model: model)

        if let prior = state.pending[requestID] {
            // Same request, later iteration. Only the output grew; adding the
            // whole record again would inflate this request 2-3x, which is
            // exactly what the raw record counts would do.
            guard usage.output > prior.output else { return TokenUsage() }
            let delta = usage.output - prior.output
            var correction = TokenUsage()
            correction.output = delta
            state.buckets[prior.bucket, default: TokenUsage()] += correction
            state.pending[requestID] = PendingRequest(
                bucket: prior.bucket, output: usage.output, lastSeen: now)
            return correction
        }

        state.buckets[bucket, default: TokenUsage()] += usage
        state.pending[requestID] = PendingRequest(
            bucket: bucket, output: usage.output, lastSeen: now)
        return usage
    }

    // MARK: Buckets

    static func bucketIndex(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 / bucketSeconds)
    }

    static func bucketKey(_ date: Date, model: String) -> String {
        "\(bucketIndex(date)):\(model)"
    }

    private func prune(now: Date) {
        let oldest = Self.bucketIndex(now.addingTimeInterval(-Self.retention))
        state.buckets = state.buckets.filter { key, _ in
            (Int(key.split(separator: ":").first ?? "") ?? 0) >= oldest
        }
        state.pending = state.pending.filter {
            now.timeIntervalSince($0.value.lastSeen) < Self.pendingTTL
        }
    }

    // MARK: Queries

    /// Usage per model over a trailing window.
    func usage(since: Date, now: Date = Date()) -> [String: TokenUsage] {
        lock.lock()
        defer { lock.unlock() }
        load()
        let from = Self.bucketIndex(since)
        var out: [String: TokenUsage] = [:]
        for (key, usage) in state.buckets {
            let parts = key.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let index = Int(parts[0]), index >= from else { continue }
            out[String(parts[1]), default: TokenUsage()] += usage
        }
        return out
    }

    func total(since: Date, now: Date = Date()) -> TokenUsage {
        usage(since: since, now: now).values.reduce(into: TokenUsage()) { $0 += $1 }
    }

    /// Tokens per minute over a trailing window, for burn rate.
    func burnRate(window: TimeInterval, now: Date = Date()) -> Double {
        let usage = total(since: now.addingTimeInterval(-window), now: now)
        return Double(usage.total) / (window / 60)
    }

    /// Whether anything has been indexed yet, so the UI can say "measuring"
    /// rather than showing a confident zero.
    var hasData: Bool {
        lock.lock()
        defer { lock.unlock() }
        load()
        return !state.buckets.isEmpty
    }
}
