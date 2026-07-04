# deskswitch — Design Spec

**Date:** 2026-07-04
**Status:** Draft, pending user approval

## Problem

A two-Mac, two-monitor desk setup (MacBook Pro M1 Pro/Max + Mac mini M4, both always on, same LAN) requires pressing physical monitor buttons to switch each display's input source between machines. This is slow and cumbersome when switching between work and personal contexts multiple times a day.

## Solution Summary

`deskswitch` is a single Swift application installed identically on both Macs. It switches monitor inputs programmatically over DDC/CI (VCP code `0x60`, the same mechanism the physical buttons use) and coordinates between the two machines over the home LAN, because a Mac can only send DDC commands to a monitor it currently drives.

## Hardware Context

| Item | Detail |
|---|---|
| Monitor 1 | Gigabyte M27Q, 2560x1440 @ 144 Hz |
| Monitor 2 | ASUS ProArt PA278CV, 2560x1440 @ 75 Hz |
| Machine A | Mac mini (Apple M4) |
| Machine B | MacBook Pro (Apple M1 Pro/Max) |
| Network | Same LAN, both machines always on |

Both Macs are Apple Silicon, so a single DDC code path (IOAVService) suffices. Both monitors are known to support DDC/CI input selection. Exact input-source codes per port are discovered empirically via a guided probe command, not hardcoded from spec sheets.

## Goals

1. Switch either monitor (or both) to either Mac from a menu bar app on whichever Mac the user is currently using — including "pull" flows where the target monitor is currently driven by the other machine.
2. Per-monitor control plus a convenience "flip both" action.
3. HTTP API so iPhone Shortcuts (and later, optionally, a native iOS app) can trigger switches.
4. CLI mode in the same binary for scripting, debugging, and future Raycast/hotkey integration.
5. Start automatically at login and recover from crashes.

## Non-Goals

- Keyboard/mouse switching (user has two Bluetooth sets, one per machine).
- Native iOS app (deferred; the HTTP API is designed so one can be added later as a separate project).
- Support for Intel Macs, more than two machines, or more than two monitors (YAGNI; config format should not actively prevent it, but no code paths for it).
- Brightness/volume or any non-input DDC control.

## Architecture

One binary, five components:

### 1. DDC engine
- Enumerates connected displays via IOKit / IOAVService (Apple Silicon path).
- Reads and writes VCP `0x60` (input select). Reading the current value provides state detection.
- Matches monitors across machines by EDID model name (`M27Q`, `PA278CV` — distinct, unambiguous).
- Isolated behind a Swift protocol so all higher layers can be tested with a mock.

### 2. HTTP API
- `Network.framework` listener on a fixed port (default `8377`), bound to LAN.
- Endpoints:
  - `GET /status` → monitors this Mac currently drives, with current input codes.
  - `POST /switch` with body `{ "monitor": "<name>", "target": "<machine>" }` → executes or forwards.
- Auth: shared static token from config, sent as a header. Home LAN threat model; token is cheap insurance.

### 3. Router
The decision brain for `switch monitor X to machine Y`:
1. If this Mac currently drives X → write DDC locally.
2. Else → forward the request to the peer's HTTP API.
3. If the peer is unreachable or nobody drives X → structured error.

### 4. Menu bar UI
- SwiftUI `MenuBarExtra`.
- Per-monitor row: monitor name, current source machine, button(s) to send it to the other machine or pull it here.
- Convenience actions: "Bring both here", "Send both away".
- State is refreshed when the menu opens (local DDC read + peer `GET /status`); no background polling.

### 5. Config
Small JSON file per machine (`~/.config/deskswitch/config.json`):

```json
{
  "machineName": "macmini",
  "peer": { "name": "macbook", "host": "macbook.local", "port": 8377 },
  "token": "<shared-secret>",
  "monitors": {
    "M27Q":    { "inputs": { "macmini": 15, "macbook": 27 } },
    "PA278CV": { "inputs": { "macmini": 15, "macbook": 17 } }
  }
}
```

Input code values above are illustrative; real values are captured by the probe flow: while a given Mac drives a monitor, `deskswitch probe` reads the current `0x60` value and records it under that machine's key.

### CLI mode
Same binary, argument-driven: `deskswitch status`, `deskswitch probe`, `deskswitch switch <monitor> <machine>`, `deskswitch serve` (agent mode). The menu bar app is the no-argument default when launched as an app bundle.

## Data Flows

- **Push** (most common): user on the Mac that drives the monitor clicks "send to other Mac" → local DDC write → monitor flips, this Mac loses the display. Display disappearance after a successful switch is the success signal, not an error.
- **Pull**: user on the Mac that does not drive the monitor clicks "bring here" → router forwards `POST /switch` to peer → peer writes DDC → monitor appears locally.
- **Phone**: iPhone Shortcut sends `POST /switch` to the Mac mini as primary target (always-on desktop); the router forwards if the MacBook actually drives the monitor. Shortcut may fall back to the MacBook if the mini is unreachable.
- **Status**: menu open → local DDC read + peer `GET /status` → render.

## Error Handling

| Failure | Behavior |
|---|---|
| Peer unreachable | Send Wake-on-LAN magic packet, retry once, then macOS notification "other Mac offline". |
| DDC write fails | Retry once, then notification naming the monitor. |
| No machine drives the requested monitor | Explicit error (notification / CLI stderr / HTTP 409). |
| Input code missing from config | Error instructing user to run `deskswitch probe`. |
| Timeouts | 2 s budget per hop; UI never blocks on network. |

## Lifecycle

- Registered as a login item via `SMAppService` (launchd `RunAtLoad` + `KeepAlive` semantics): starts at login, restarts on crash.
- Optional (config flag): while a Mac is headless (drives no monitors), the agent holds a power-management assertion to prevent sleep so it stays reachable for pull requests. Wake-on-LAN is the fallback if it sleeps anyway.

## Testing Strategy

- **Unit (TDD):** router decisions, config parsing/validation, HTTP handler behavior — all against mocked DDC engine and mocked peer client. This is the pure-logic layer and the primary test surface.
- **Hardware integration:** DDC engine verified manually on the real setup via CLI (`probe`, `status`, `switch`), with a written verification checklist per milestone. No mocked-IOKit theater.
- **End-to-end:** scripted `curl` runs against live agents on both machines, covering push, pull, and both-monitor flips in both directions.

## Implementation Milestones

Each milestone is independently shippable and useful; stop after any of them and the tool still works.

1. **M1 — DDC core + CLI.** Display enumeration, probe, status, switch, config file. Push flows work from the terminal. Physical buttons already obsolete for the common case.
2. **M2 — HTTP API + router.** Agent mode, peer forwarding, token auth. Pull flows work via `curl`; iPhone Shortcuts become possible here, before any UI exists.
3. **M3 — Menu bar UI.** SwiftUI `MenuBarExtra` over the same core: per-monitor rows and switch buttons (convenience "flip both" actions land in M4).
4. **M4 — Polish.** `SMAppService` autostart, Wake-on-LAN, notifications, flip-both actions, headless sleep prevention.

## Risks / Open Questions

- **DDC quirks:** the M27Q is community-reported to have flaky DDC over some HDMI paths (works reliably over DisplayPort/USB-C). If probe/switch misbehaves on a given port, the fix is usually re-cabling that machine to DP/USB-C. Discoverable in M1.
- **Input code stability:** codes are per-monitor-port, so recabling requires re-running probe. Acceptable for a fixed home desk.
- **MacBook clamshell sleep:** covered by the sleep-prevention assertion + WoL, but real-world behavior needs the M4 verification checklist.
