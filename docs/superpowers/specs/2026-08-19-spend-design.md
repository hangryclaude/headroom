# Spend — Estimated API value in Headroom

**Status:** approved (Codex-reviewed, 2026-08-19) · not yet planned
**Scope guard:** this feature must not modify or depend on the uncommitted
Keychain/swap changes in the working tree (`AccountVault.swift`, `Keychain.swift`,
`Store.swift`, `build.sh`). Edits to `PopoverView.swift` and `SelfTest.swift`
must be additive and separable. Nothing is committed or installed as part of
this spec.

## What it is

A popover section showing token totals for all Claude Code usage on this Mac —
which, because every account writes to the same `~/.claude/projects`, is the
all-accounts number. **Tokens lead; dollars are a footnote.** (Angus,
2026-08-19: "I don't care about money. I just care about tokens.")

```
Tokens
  Today        512 M
  This month   9.04 B
  All time     9.04 B
  ▸ per model / read-write split
  est. API value $7,424 · rates as of 2026-08
```

The primary rows show total tokens moved (input + output + cache read + cache
write). The disclosure shows per-model rows and the read/write/output split.
The single dollar figure is labeled **"est. API value"** — sticker-rate
equivalent of tokens consumed, not money billed. Reference answer, verified
2026-08-19 by independent parse + ccusage cross-check + 3-agent adversarial
audit: 9,043,823,770 tokens (8.64 B cache reads, 330.7 M cache writes,
68.2 M output, 1.2 M fresh input) ≈ $7,424 (with Sonnet 5 intro pricing) /
$7,888 (sticker) for 2026-08-05 → 08-19, 61,753 requests.

## Why not per-account

Transcripts do not record which account was active; a retroactive split is
impossible. Forward-only attribution (Headroom performs every swap, so it can
log swap times and attribute buckets from now on) is **slice 2, out of scope
here** — this spec covers the machine-wide total only.

## Architecture

### SpendIndexer: a second TranscriptIndexer instance, fully isolated

Reuse the existing `TranscriptIndexer` class, instantiated a second time with
its own configuration and its own state file. No shared mutable state with the
live 5-minute quota indexer.

| | Live indexer (unchanged) | SpendIndexer (new config) |
|---|---|---|
| State file | existing | `spend-index.json` (new) |
| First sight of a file | starts near EOF (cold-start cap) | starts at byte 0 (backfill) |
| Bucket granularity | 5-minute | **1-hour, keyed in UTC**: `"YYYY-MM-DDTHH\|model"` |
| Request dedup | in-file pending map | persistent global dedup (below) |

`TranscriptIndexer` gains a configuration struct (first-sight policy, bucket
granularity, dedup policy, state path) whose defaults reproduce today's
behavior byte-for-byte. **Regression tests must prove the live indexer's
observable behavior and state format are unchanged** (same fixture in → same
state JSON out, before and after this change).

Backfill progress lives entirely in `spend-index.json` (per-file `offset`,
`size`, `done` marker, keyed by **realpath**). It can never rewind or corrupt
the live indexer's cursors because it never reads or writes them.

### File enumeration

Enumerate `~/.claude/projects/**/*.jsonl`, canonicalize every path with
realpath, and dedupe before scanning. (Measured on this machine: 4 symlinked
workflow dirs cause 190 files to be listed twice; request-level dedup makes
this financially inert, but file-level dedup avoids the wasted I/O.)

### Global request dedup — persistent and bounded

Streaming writes one assistant record per iteration sharing a `requestId`
(output grows; input/cache fields fixed — verified on all 150,493 usage records
on this machine, zero violations). Duplicate physical files and session forks
can also repeat a requestId across files. Rules:

- **Identity:** `requestId`, else `message.id`, else hash of
  `(file realpath, byte offset)` — every usage record gets exactly one identity;
  nothing billable is dropped.
- **Merge:** max-merge every usage field per identity (output last-wins is
  subsumed by max; verified monotonic on real data).
- **Persistence:** identities stored as 64-bit hashes in `spend-index.json`,
  with the UTC day last seen. Survives restart, so a resumed backfill or a
  shrunk-and-rescanned file cannot double count.
- **Bound:** when the set exceeds 500k entries, evict hashes last seen more
  than 90 days ago. Cross-file duplicates are temporally local (forks and
  symlinked copies are written in the same period), so the eviction horizon is
  safe; the bound caps the state file at single-digit MB.
- `<synthetic>` records are skipped (verified: their usage is always all-zero).

### Backfill lifecycle

- Runs on a background queue at `.utility` QoS. Chunked reads (4 MB), state
  persisted after each file, ~50 ms yield between chunks so a cold 642 MB+
  backfill never makes the Mac feel busy.
- **Cancellation:** app quit or explicit cancel stops after the current chunk;
  state is already durable, next launch resumes from per-file offsets.
- **Corrupted/undecodable lines:** skipped, counted (surfaced in `--selftest`
  diagnostics), never fatal.
- **Truncated/rotated files** (size < stored offset): treat as a new file —
  rescan from byte 0; the persistent dedup set absorbs any re-seen requests.
- After backfill (`done` on all files), the same instance tails files
  incrementally exactly like the live indexer, keeping Spend current.
- UI during backfill: `scanning history… 62%` (files done / total).

## Pricing

- Store **tokens, never dollars**. Dollars are computed at render time from
  `Pricing.rates`, so a rate-table update automatically reprices all history.
- `Pricing` gains an `asOf` constant (e.g. `"2026-08"`); the UI footnotes
  "rates as of 2026-08" — that constant is the pricing-version provenance.
- Sticker rates only. Promotional windows (Sonnet 5 intro $2/$10 through
  2026-08-31) are deliberately not modeled; the label "Estimated" covers this.
- Cache tiers priced as today: read 0.1×, write-5m 1.25×, write-1h 2× —
  keeping the 5m/1h split `TranscriptIndexer` already extracts.

### Rounding

- Accumulate in integer tokens; convert to `Double` dollars per (model, hour
  bucket) only at render.
- Sum per-model costs, then round **once, at display**: half away from zero;
  cents below $100, whole dollars at ≥ $100.
- Selftest asserts computed cost within $0.005 of the fixture's expected value.

## Calendar boundaries

- Buckets are stored in **UTC hours**. "Today", "This month", and "All time"
  are computed at render by grouping UTC hour buckets into the Mac's **current**
  calendar and timezone (`Calendar.current`, live `TimeZone.current`).
- Consequence, documented in the UI footnote: figures follow the Mac's clock.
  Changing timezone re-groups history correctly on next render — no stored
  rebucketing needed, because storage is finer-grained (hourly) than display.
  A record at 23:30 PT counts toward the PT day, and toward the London day if
  the Mac later moves to London. "Today" = midnight-to-now local; "This month"
  = 1st-of-month-to-now local.

## UI

- New `SpendSection` view in the popover: three rows (Today / This month /
  All time) under the header **Tokens**, each showing total tokens moved in
  humane units (M/B, one decimal). Disclosure reveals per-model rows
  (model, requests, tokens) and the output / cache-read / cache-write split.
  Footnote is the only dollar figure: "est. API value $N · sticker rates as
  of {Pricing.asOf} · not billed spend".
- One insertion point in `PopoverView.swift`; everything else in new files.
- Rendering must go through the existing fixture path: screenshots via
  `HEADROOM_HOME=<fixture>`, never `--render` against live data.

## Testing

Fixture (`HEADROOM_HOME`) containing:

1. streaming duplicates — one requestId, three records, growing output;
2. the same physical file reachable via a symlinked dir **and** its canonical
   path;
3. a record with no `requestId` (falls back to `message.id`) and one with
   neither (falls back to file+offset identity);
4. a corrupted line and a `<synthetic>` record;
5. a file that shrinks between two scans.

Assertions:

- exact token totals per model and cost within $0.005;
- symlink+canonical duplication changes nothing;
- rescan after shrink changes nothing (dedup absorbs it);
- **migration/regression:** the live 5-minute indexer, run on its existing
  fixture before and after this change, produces identical state JSON and
  identical bucket output; loading a pre-existing live state file is untouched
  by SpendIndexer runs.
- `--selftest` remains data-dependent per repo convention — new assertions are
  fixture-scoped, not live-count-scoped.

## Rejected alternatives

- **Separate one-shot scanner** — duplicates cursor/tail logic already proven
  in `TranscriptIndexer`.
- **Shell out to ccusage** — new dependency; prices all cache writes at 1.25×,
  underpricing 1-hour writes by 37% (measured $273 low on this machine's data).
- **Storing dollars** — freezes pricing errors into history; tokens + render-
  time pricing reprices for free.
- **Local-day bucket keys** — breaks on timezone changes; UTC hours + render-
  time grouping doesn't.
