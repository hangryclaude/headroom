#!/usr/bin/env python3
"""Build the throwaway $HOME that the README screenshots are rendered against.

`Headroom --render` photographs the real views with the real Store in them, so
whatever is on disk is what ends up in the images. Pointing HEADROOM_HOME at a
tree written from here means the shots carry invented accounts and an invented
week instead of the author's, and that the same numbers come back on a rebuild.

    python3 docs/fixture.py /tmp/headroom-fixture

Everything is dated relative to the moment it runs, because the weekly pace
reading is a function of how much of the window has elapsed -- a tree with fixed
timestamps would drift into a different picture every day.
"""

import hashlib
import json
import os
import shutil
import sys
from datetime import datetime, timedelta, timezone

# Cocoa's reference date. JSONEncoder's default strategy writes Date as seconds
# since 2001-01-01, not since the Unix epoch, so accounts.json has to as well.
CF_EPOCH = 978307200

HOUR = 3600
DAY = 24 * HOUR
WEEK = 7 * DAY


# ---------------------------------------------------------------- the week
#
# 74% of the weekly budget spent with 61% of the window elapsed. Chosen, not
# arbitrary: it is the one reading that exercises every part of the surface at
# once. The pace tick lands visibly behind the fill edge, the panel's chart gets
# a long run of actual spend separated far enough from the budget line to read
# as above it, and the projection clears the 25%-elapsed threshold so the app is
# willing to name a day rather than declining to guess.
#
# Kept close to the 70 warning mark on purpose. The accent then appears at low
# intensity, which is the honest way to photograph a rule whose whole point is
# that it stays quiet -- a screenshot pinned at 95% would show the colour but
# misrepresent the restraint.

WEEKLY_PERCENT = 74
WEEKLY_RESETS_IN = 2 * DAY + 17 * HOUR

SESSION_PERCENT = 43
SESSION_RESETS_IN = 2 * HOUR + 51 * 60

SCOPED_MODEL = "Fable"
SCOPED_PERCENT = 18
SCOPED_RESETS_IN = WEEKLY_RESETS_IN

ACTIVE_UUID = "8f14e45f-ceea-467a-9f0b-1c2d3e4f5a6b"
ORG_UUID = "3c59dc04-8e88-4e35-b1a0-9d7f6c5b4a32"

ACTIVE = {
    "email": "you@example.com",
    "uuid": ACTIVE_UUID,
    "tier": "default_claude_max_20x",
}

# The other two logins. No credential is written for them: a fixture cannot hold
# a token the usage endpoint would accept, and inventing one only swaps "needs
# login" for "token expired" after a doomed round trip. The remembered figures
# are what the vault records on the way out of an account, so the rows still
# carry a real measurement and a real age.
SAVED = [
    {"email": "you@company.com", "uuid": "b3f1c2d4-5e6a-4b7c-8d9e-0f1a2b3c4d5e",
     "weekly": 24, "session": 9, "seen_hours_ago": 3},
    {"email": "you@side.dev", "uuid": "c4e2d3f5-6a7b-4c8d-9e0f-1a2b3c4d5e6f",
     "weekly": 52, "session": 21, "seen_hours_ago": 5},
]


# ------------------------------------------------------------------- spend
#
# A heavy but ordinary day on one subscription, per model. Kept under $1000 and
# under a billion tokens on purpose: the panel is making an argument about where
# tokens go, and a figure large enough to be read as a flex is a figure nobody
# believes. Cache reads still outweigh output ~40x, which is the argument.
#
# (input, output, cache_read, cache_write_5m, cache_write_1h) in millions.
WORKLOAD = [
    ("claude-opus-5",             0.48, 3.10, 180.0, 14.00, 2.40),
    ("claude-sonnet-5",           0.11, 0.89,  42.0,  3.10, 0.00),
    ("claude-haiku-4-5-20251001", 0.24, 0.31,   6.2,  0.00, 0.00),
]

# How many requests each model's day is spread across, and how much of it landed
# in the last hour -- that trailing hour is what the panel's burn rate measures.
REQUESTS = 46
LAST_HOUR_SHARE = 0.038


def iso(when):
    return when.astimezone(timezone.utc).isoformat(timespec="microseconds")


def write(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        if isinstance(payload, str):
            handle.write(payload)
        else:
            json.dump(payload, handle, indent=2)


def limits(now):
    """The `limits[]` array, in the shape both the endpoint and the on-disk
    cache use."""
    return [
        {
            "kind": "session",
            "percent": SESSION_PERCENT,
            "resets_at": iso(now + timedelta(seconds=SESSION_RESETS_IN)),
            "is_active": True,
        },
        {
            "kind": "weekly_all",
            "percent": WEEKLY_PERCENT,
            "resets_at": iso(now + timedelta(seconds=WEEKLY_RESETS_IN)),
            "is_active": True,
        },
        {
            "kind": "weekly_scoped",
            "percent": SCOPED_PERCENT,
            "resets_at": iso(now + timedelta(seconds=SCOPED_RESETS_IN)),
            "is_active": True,
            "scope": {"model": {"id": None, "display_name": SCOPED_MODEL}},
        },
    ]


def claude_json(now):
    """`~/.claude.json` -- identity and the quota cache, in one file, the way
    Claude Code keeps it.

    `fetchedAtMs` is set 4 minutes back rather than to now: the cache only
    refreshes when Claude Code talks to the server, so a reading a few minutes
    old is the resting state, and the popover says so in words. Zero would
    photograph as "read just now", which is the rarer case.
    """
    return {
        "oauthAccount": {
            "accountUuid": ACTIVE["uuid"],
            "emailAddress": ACTIVE["email"],
            "organizationUuid": ORG_UUID,
            "organizationType": "claude_max",
            "organizationRateLimitTier": ACTIVE["tier"],
        },
        "cachedUsageUtilization": {
            "fetchedAtMs": int((now.timestamp() - 4 * 60) * 1000),
            "accountUuid": ACTIVE["uuid"],
            "utilization": {"limits": limits(now)},
        },
        # Present so the shape is honest about what the file really holds --
        # these are the keys a whole-file copy would drag along with the
        # identity, which is why the app edits it surgically instead.
        "numStartups": 412,
        "projects": {},
        "mcpServers": {},
    }


def credentials(now):
    access = "fixture-access-" + ACTIVE["uuid"]
    refresh = "fixture-refresh-" + ACTIVE["uuid"]
    blob = {
        "claudeAiOauth": {
            "accessToken": access,
            "refreshToken": refresh,
            "expiresAt": int((now.timestamp() + 30 * DAY) * 1000),
            "scopes": ["user:inference", "user:profile"],
            "subscriptionType": "max",
        }
    }
    fingerprint = hashlib.sha256(access.encode() + refresh.encode()).hexdigest()
    return blob, fingerprint


def accounts_index(now, fingerprint):
    """The vault index. `savedAt` and friends are Cocoa reference-date seconds."""
    def cf(seconds_ago):
        return now.timestamp() - seconds_ago - CF_EPOCH

    index = [{
        "name": ACTIVE["email"],
        "email": ACTIVE["email"],
        "plan": "Max 20x",
        "accountUUID": ACTIVE["uuid"],
        "fingerprint": fingerprint,
        "savedAt": cf(21 * DAY),
        "lastActiveAt": cf(6 * HOUR),
    }]

    for saved in SAVED:
        index.append({
            "name": saved["email"],
            "email": saved["email"],
            "plan": "Max 20x",
            "accountUUID": saved["uuid"],
            "fingerprint": hashlib.sha256(saved["uuid"].encode()).hexdigest(),
            "savedAt": cf(18 * DAY),
            "lastActiveAt": cf(saved["seen_hours_ago"] * HOUR),
            "lastSessionPercent": saved["session"],
            "lastWeeklyPercent": saved["weekly"],
            "usageFetchedAt": cf(saved["seen_hours_ago"] * HOUR),
        })
    return index


def transcripts(now):
    """`projects/<dir>/<session>.jsonl` -- assistant records carrying usage.

    One record per request id. The indexer's streaming-duplicate rule is
    exercised by --selftest against a real transcript; repeating records here
    would only make the totals harder to reason about.
    """
    lines_by_file = {}

    for model, *millions in WORKLOAD:
        totals = [int(m * 1_000_000) for m in millions]
        recent = max(1, int(REQUESTS * LAST_HOUR_SHARE * 8))
        older = REQUESTS - recent

        # Split each model's day: most of it spread back over 23 hours, a slice
        # of it inside the last hour so the burn rate has something to measure.
        plan = []
        for i in range(older):
            age = 23 * HOUR - (i * (22 * HOUR) // max(older - 1, 1))
            plan.append((age, (1 - LAST_HOUR_SHARE) / older))
        for i in range(recent):
            age = 55 * 60 - (i * (50 * 60) // max(recent - 1, 1))
            plan.append((age, LAST_HOUR_SHARE / recent))

        handle = model.replace(".", "-")
        path = f"projects/-Users-you-dev-headroom/{handle}.jsonl"
        lines = lines_by_file.setdefault(path, [])

        for n, (age, share) in enumerate(plan):
            when = now - timedelta(seconds=age)
            usage = [max(1, int(total * share)) for total in totals]
            # Compact separators are not cosmetic. The indexer skips lines
            # without paying for a JSON parse by scanning for the literal bytes
            # `"type":"assistant"`, so a space after the colon makes every
            # record here invisible to it.
            lines.append(json.dumps({
                "type": "assistant",
                "requestId": f"req_{handle}_{n:03d}",
                "timestamp": iso(when),
                "message": {
                    "model": model,
                    "usage": {
                        "input_tokens": usage[0],
                        "output_tokens": usage[1],
                        "cache_read_input_tokens": usage[2],
                        "cache_creation": {
                            "ephemeral_5m_input_tokens": usage[3],
                            "ephemeral_1h_input_tokens": usage[4],
                        },
                    },
                },
            }, separators=(",", ":")))

    return lines_by_file


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: fixture.py <directory>")

    root = os.path.abspath(sys.argv[1])

    # This function's whole job is to write a tree that something else will
    # treat as $HOME, so it must never be pointed at a real one. Only a
    # directory that is empty or that a previous run clearly made gets replaced.
    if os.path.exists(root):
        marker = os.path.join(root, ".claude.json")
        if os.listdir(root) and not os.path.exists(marker):
            sys.exit(f"refusing to replace {root}: not empty and not a fixture tree")
        shutil.rmtree(root)

    now = datetime.now(timezone.utc)

    write(os.path.join(root, ".claude.json"), claude_json(now))
    write(os.path.join(root, ".claude/settings.json"), {"model": "opus"})

    # Empty, so SessionGuard reports a clear machine and the switch controls
    # photograph enabled rather than held.
    os.makedirs(os.path.join(root, ".claude/sessions"), exist_ok=True)

    blob, fingerprint = credentials(now)
    vault = os.path.join(root, "Library/Application Support/Headroom/vault")
    write(os.path.join(vault, "accounts.json"), accounts_index(now, fingerprint))
    write(os.path.join(vault, ACTIVE["email"], "credentials.json"), blob)

    for path, lines in transcripts(now).items():
        write(os.path.join(root, ".claude", path), "\n".join(lines) + "\n")

    print(root)


if __name__ == "__main__":
    main()
