# Accessing your Loop data locally

Loop stores everything it records or imports in **one local SQLite database on your device** — no
cloud, no account. This document is the **stable contract** for reading that data from another
project on the same Mac (a companion tool, a script, an LLM workflow, …).

> **Read through the CLI, not the raw DB.** The SQLite schema is Loop's *internal* structure and
> changes with upstream migrations (the `workout` table itself only arrived in schema v8). The
> `loop-data` CLI below is the boundary you should code against: its JSON output is what we keep
> stable. If you read the `.sqlite` file directly you're coupling to internals that can shift under
> you on any upstream sync.

---

## Where the data lives

The sandboxed macOS Loop build keeps its store at:

```
~/Library/Containers/com.ecmode.loop/Data/Library/Application Support/OpenWhoop/whoop.sqlite
```

(plus `-wal` / `-shm` sidecars; the DB is in WAL mode). You may also see
`~/Library/Containers/com.noopapp.noop/...` (the *official* NOOP app) and a legacy
`~/Library/Application Support/OpenWhoop/...` copy — the path above is Loop's.

On **iOS** the same DB is in the app's private, protected container and is **not** reachable from
another app (it isn't in the shared App Group). Use CSV export or a HealthKit/Strava bridge there;
this CLI is the macOS story.

---

## The `loop-data` CLI

A standalone, read-only exporter in this repo. It opens the store **read-only** (never writes,
never checkpoints the WAL — safe to run while the Loop app is open) and emits JSON, NDJSON, or a
markdown table.

### Build

```sh
cd Tools/loop-data
swift build -c release
# binary at: .build/release/loop-data
# optional: cp .build/release/loop-data /usr/local/bin/loop-data
```

No external dependencies (links only the system SQLite3), so it builds offline.

### Commands

| Command | What it returns |
| --- | --- |
| `workouts` | Workouts: sport, start/end, duration, distance, HR, strain, HR-zones |
| `sleeps` | Sleep sessions: efficiency, resting HR, HRV, stages |
| `daily` | Daily metrics: recovery, strain, HRV, resting HR, sleep, steps, SpO₂, skin-temp, resp rate |
| `devices` | The device ids / sources present, with row counts (run this first to see what to filter on) |
| `help` | Usage |

### Options

| Flag | Meaning |
| --- | --- |
| `--since YYYY-MM-DD` | Start of range, inclusive (default: earliest) |
| `--until YYYY-MM-DD` | End of range, inclusive (default: today) |
| `--source NAME` | Filter `workouts` by the `source` column (see **Sources** below) |
| `--device ID` | Filter by `deviceId` |
| `--limit N` | Max rows (default 100000) |
| `--format FMT` | `json` (default), `ndjson`, or `markdown` |
| `--pretty` / `--compact` | Pretty-print JSON (default) or single-line |
| `--db PATH` | Override the store path |

### Examples

```sh
loop-data devices                                  # discover sources
loop-data workouts --since 2026-01-01 --format json
loop-data workouts --source manual --format markdown
loop-data sleeps --since 2026-06-01
loop-data daily --since 2026-06-25 --format ndjson
```

---

## JSON shapes

Times come as both `startTs`/`endTs` (unix seconds) and `start`/`end` (local ISO-8601). Missing
values are `null`.

### `workouts`

```json
{
  "deviceId": "my-whoop",
  "source": "manual",
  "sport": "Running",
  "startTs": 1782776770, "start": "2026-07-01T16:46:10-07:00",
  "endTs":   1782780277, "end":   "2026-07-01T17:44:37-07:00",
  "durationS": 3507.47,
  "distanceM": 6427.24,
  "energyKcal": 512,
  "avgHr": 97, "maxHr": 127,
  "strain": 6.72,
  "zones": [ ... ],      // parsed from zonesJSON; HR-zone percentages, or null
  "notes": null
}
```

### `sleeps`

```json
{
  "deviceId": "my-whoop-noop",
  "startTs": ..., "start": "...", "endTs": ..., "end": "...",
  "durationMin": 372.35,
  "efficiency": 0.9839,
  "restingHr": 42,
  "avgHrv": 56.13,
  "userEdited": false,        // true if you hand-edited the night
  "startTsAdjusted": null,
  "stages": [ ... ]           // parsed from stagesJSON; per-stage spans, or null
}
```

### `daily`

Keyed by `day` (`YYYY-MM-DD`) **and** `deviceId` — expect one row per source per day. Columns:
`recovery`, `strain`, `avgHrv`, `restingHr`, `totalSleepMin`, `efficiency`, `deepMin`, `remMin`,
`lightMin`, `disturbances`, `exerciseCount`, `spo2Pct`, `skinTempDevC`, `respRateBpm`, `steps`,
`activeKcalEst`.

---

## Sources (what `deviceId` / `source` mean)

Loop keeps rows from different origins side by side; pick the one you want with `--source` /
`--device`, or read the `deviceId` field and filter yourself.

| Value | Meaning |
| --- | --- |
| `apple-health` | Imported from Apple Health |
| `my-whoop` | Imported from a WHOOP CSV export (real historical dates) |
| `manual` | A workout you logged / imported manually |
| `<id>-noop` (e.g. `my-whoop-noop`) | **Computed on-device** — recovery / strain / sleep staging Loop derived itself |
| bare strap id | Live data straight off the strap over BLE |

The `-noop` suffix is the tell for *computed* rows; bare ids are *imported* or *live*. For "Loop's
own scores" use the `-noop` device; for "as WHOOP/Apple recorded it" use the bare/`apple-health`
source.

---

## Stability & safety

- **Read-only.** The CLI opens with `SQLITE_OPEN_READONLY`; it cannot modify or corrupt your data,
  and is safe to run while Loop is open.
- **The JSON field names are the contract.** They won't be renamed under you. The underlying SQLite
  columns can and do change across upstream syncs — that churn is absorbed here, in one place.
- **If a column disappears upstream**, the CLI fails *loudly* (a SQL error), not silently — that's
  the signal to update `Tools/loop-data`, and your companion's contract stays put.
