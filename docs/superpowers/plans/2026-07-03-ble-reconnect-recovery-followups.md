# BLE Auto-Reconnect Recovery — Shipped Change + Breadcrumb-Gated Follow-Ups

## Incident (2026-07-03)

A WHOOP 5/MG night scored ~2h. Root-caused from a raw-sensor CSV export (Settings → Advanced →
"Export raw sensor data (CSV)"): every stream (HR, gravity, R-R, steps) **hard-stopped at 01:46 PDT
mid-sleep** — HR 50 bpm, motionless gravity, i.e. the user was clearly asleep — and never resumed until
a **manual Connect** the next morning. Detection correctly scored only the ~2h of data that reached the
phone; the user's manual extension then restaged the no-data region as a fabricated 289-min "deep" block
(later self-healed by `Repository.selfHealEditedStages` once… no data ever arrived for it, so it stood).

Observed over the ~18h before the drop:
- The strap emits `STRAP_CONDITION_REPORT` every **601s** (rock-steady 10 min). The BLE link drops locked
  to that cadence (connected periods cluster at exactly 9–10 min) and reconnects cleanly in ~6s. This
  ~10-min "flapping" is **strap-driven and benign** — 103 clean 6-second reconnects. It is NOT the
  keepAlive 600s fuse (disproved: `lastDataAt` is refreshed on every notification incl. live 1 Hz HR at
  `BLEManager.swift` `didUpdateValueFor`, so that fuse cannot fire while HR streams).
- `SET_RTC` ~96× is a **symptom** of the reconnects (5/MG re-clocks on every connect by design), not an
  independent clock-corruption loop.

The lost night was the **single terminal drop** that never auto-recovered. Three park paths stop the
reconnect schedulers with **no re-arm** (only a manual Connect / genuine bond / user disconnect revives
them):
- Bond-loop pause (`autoReconnectPausedForBondLoop`, #617/#844).
- Bond-refusal give-up (5 strikes, #747/#750).
- `peerRemovedPairingInformation` → `return` in `didFailToConnect` (no reschedule).

Non-pairing connect failures already self-recover (capped 60s exponential backoff), so they are not the
gap.

**Unresolved from the export alone:** the terminal event logged a *successful* reconnect (UP 01:45:53,
SET_RTC 01:45:55) then silence with **no `didDisconnect` ever logged**. That signature points at the app
being **suspended by iOS** (normal state for a `bluetooth-central` app — it is woken per BLE event, not
kept running; a `DispatchSource` timer and the keepAlive watchdog are both frozen while suspended), with
the link either silently stalled (zombie) or dropped without a delivered callback. We could not
distinguish zombie-stall vs. clean-disconnect vs. jettison/crash vs. give-up.

## Shipped (this change)

1. **Slow self-recovery timer** (`BLEManager.reconnectRecoveryTimer`, `reconnectRecoveryIntervalSeconds =
   1200` / 20 min). Armed at all three park sites (`armReconnectRecovery(reason:)`); on each tick, if
   still disconnected and not intentional, it retries `connect()`. Cancelled on a real `didConnect`, on
   `disconnect()`, and on `forgetDevice()`. Slow enough not to reintroduce the tight-loop battery drain
   the pauses exist to prevent; self-healing so an unattended strand recovers without a manual tap.
   **Limitation:** a `DispatchSource` timer cannot fire while the app is suspended, so this covers the
   give-up-path case and the app-alive-in-background case, NOT a pure suspended silent-stall.

2. **Always-on breadcrumbs** (persist to the exportable strap log via `log()`, no test mode needed):
   - The three park sites log `Auto-reconnect paused (reason=bondLoop|bondRefusal|peerRemovedPairing)`.
   - `BLEManager.noteForegroundResume()` — wired into `StrandiOSApp` scenePhase `.active` — logs, when the
     app foregrounds after ≥120s of silence:
     `Resume after data gap=<s>: cbState=<…> appConnected=<bool> bonded=<bool>
      autoReconnectPaused=<bool> parkReason=<…> recoveryTimer=<armed|off>`.

Both typecheck-verified (macOS `Strand` + `NOOPiOS` builds). Not runtime-verified (needs a night on-strap).

## Follow-up decision tree — keyed on the resume breadcrumb of the NEXT occurrence

Read the `Resume after data gap=…` line (and any preceding `Auto-reconnect paused` line) after the next
short-night incident, then branch:

### A. `parkReason` set (bondLoop / bondRefusal / peerRemovedPairing), recoveryTimer=armed
A give-up path fired and the 20-min recovery timer was running. Check whether it actually recovered
overnight (look for a later `Auto-reconnect recovery: retrying` → `didConnect`).
- **Recovered on its own** → the shipped fix works; consider tightening the interval if the gap was large.
- **Did NOT recover** (timer never fired) → the app was suspended even though a give-up fired → treat as
  case C (needs a suspension-surviving mechanism). Size: **M**.

### B. `cbState=connected` + large gap  → ZOMBIE LINK (silent stall)
CoreBluetooth still thinks it's connected but no data arrived for hours — no `didDisconnect`, keepAlive
frozen while suspended. This is the hardest case and the most likely one here.
- **Follow-up:** a suspension-surviving stall detector. Options, least→most invasive:
  1. On `noteForegroundResume()`, if `cbState=connected` && gap > fuse, **actively bounce** the link
     (`cancelPeripheralConnection` → the existing 3s rescan) instead of only logging. Cheap, recovers on
     foreground at least. Size: **S**.
  2. A `BGProcessingTask` (already have BG infra for the scheduled export, #510) that wakes periodically
     to check `lastDataAt` and bounce a stale-but-connected link while backgrounded. Unreliable timing but
     the only OS-sanctioned suspended-wake for this. Size: **M**.
  3. Investigate whether the strap can be kept from entering the silent state at all (firmware/handshake).
     Size: **L**, low confidence.

### C. `cbState=disconnected` + no parkReason  → clean drop that didn't reschedule
The link dropped (didDisconnect fired) but the 3s rescan / 60s backoff didn't bring it back — most likely
the app was suspended right after the drop and the pending `connect()` never completed.
- **Follow-up:** issue a **background-honored pending `central.connect(p, options: nil)`** at the park/drop
  sites (iOS services it while suspended and wakes the app on link-up). This is the real fix for the
  suspended-reconnect case and complements the timer. Watch for battery cost against a refusing strap
  (bound it: single outstanding pending connect, not a loop). Size: **M**.

### D. `cbState=noPeripheral`  → cold relaunch (app was terminated/jettisoned)
The app was killed overnight and relaunched fresh in the morning without auto-connecting (hence the manual
Connect).
- **Follow-up:** auto-initiate a connect on cold launch when a strap is pinned + state restoration has a
  restored peripheral, so the user never has to tap Connect after a jettison. Verify
  `willRestoreState`/`CBCentralManagerOptionRestoreIdentifierKey` actually relaunches this build. Size:
  **S–M**.

### Cross-cutting (optional, only if flapping correlates with terminal drops)
The ~10-min strap-driven flapping is benign in isolation, but each forced re-pair is a fresh opportunity
to land in a dead-end. If breadcrumbs show terminal drops cluster right after a re-pair, consider reducing
forced re-pairs (e.g. suppress the redundant SET_RTC / hold the link across the condition report). Size:
**M**, do NOT pursue speculatively.

## How to collect the next occurrence
User exports the raw-sensor CSV (for the signal timeline) AND the strap log (Settings → the "Grab this
when you report a bug" diagnostic / Live log — carries the always-on breadcrumbs). The `Resume after data
gap=…` line is the decider.
