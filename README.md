# deskswitch

Move your monitors between two Macs without touching the monitor buttons.

`deskswitch` is a single Swift binary — installed on both machines — that switches your external monitors' input sources over **DDC/CI**, from a **menu-bar app**, the **command line**, or an **HTTP API**. If a monitor is currently driven by the *other* Mac, the request is forwarded over your LAN (with optional Wake-on-LAN), so one keystroke or one menu click hands a display from one machine to the other.

It's built for a specific, common setup: **two always-on Apple Silicon Macs sharing the same monitors**, each wired to a different input on each display.

---

## Features

- **One binary, three front-ends** — a SwiftUI `MenuBarExtra` app, an `ArgumentParser` CLI, and an HTTP agent, all sharing the same routing logic.
- **Local or remote, automatically** — writes DDC directly when this Mac drives the monitor; otherwise forwards the request to the peer over HTTP.
- **Flip one or flip both** — switch a single monitor or send/pull both at once.
- **Wake-on-LAN** — optionally wake a sleeping peer with a magic packet before forwarding, with a single retry.
- **Launch at login** — registers a `SMAppService` LaunchAgent that restarts the app on crash but stays quit on a clean quit.
- **Stay awake when headless** — optionally hold a `PreventSystemSleep` assertion while this Mac drives no external displays, so it remains reachable.
- **No hard-coded monitors or input codes** — displays are matched by EDID product name; input codes are discovered per-machine with `deskswitch probe`.

## Requirements

- **macOS 14+**, **Apple Silicon (arm64)** — DDC/CI is done through the private-but-exported `IOAVService*` symbols (resolved at runtime with `dlsym`, the same mechanism [`m1ddc`](https://github.com/waydabber/m1ddc) uses). There is no Intel / `ddcctl` fallback.
- **Exactly two Macs** on the same LAN, each cabled to the shared monitors.
- Monitors that support **DDC/CI input-source switching** (VCP feature `0x60`). Reliability varies by monitor and by connection — see [Hardware notes](#hardware-notes).
- One dependency: [`swift-argument-parser`](https://github.com/apple/swift-argument-parser).

## How it works

```
                 ┌─────────────────── Mac A (macmini) ───────────────────┐
   menu / CLI ──▶│  Router ──▶ drives this monitor? ──yes──▶ DDC write   │──▶ monitor
   HTTP  ───────▶│                     │                                 │
                 │                     └──no──▶ HTTP + Wake-on-LAN ───────┼──▶ Mac B
                 └───────────────────────────────────────────────────────┘
```

- The **core library** (`DeskSwitchCore`) holds all the pure logic — config, the router, the DDC/HTTP packet codecs, EDID parsing, and the menu view-model — and is unit-tested with mocks.
- The **executable** (`deskswitch`) holds the hardware and UI: the `IOAVService` DDC engine, the CLI, and the SwiftUI menu-bar app.
- The **router** decides, per request, whether to write DDC locally or forward to the peer. A `WakingPeerClient` decorator wraps the HTTP client to send a Wake-on-LAN packet and retry once when the peer is unreachable.
- A push that hands a display *away* is treated as **success**, not verified by read-back — the display detaches from this Mac because it's now showing the other one.

## Install

Build the release binary and tests:

```bash
swift build -c release
swift test          # requires full Xcode (XCTest); e.g. DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Build the menu-bar app bundle and install it on **both** Macs:

```bash
scripts/make-app.sh                 # produces build/DeskSwitch.app (ad-hoc signed)
cp -R build/DeskSwitch.app /Applications/
open /Applications/DeskSwitch.app
```

The app runs as a menu-bar item with no Dock icon (`LSUIElement`) and embeds the HTTP agent, so you don't need a separate `serve` process when the app is running.

## Configure

Create `~/.config/deskswitch/config.json` on **each** Mac. The two files mirror each other: each machine's `machineName` is the other's `peer.name`, and both hold the full input-code map for every monitor.

```jsonc
{
  "machineName": "macmini",
  "peer": {
    "name": "macbook",
    "host": "macbook.local",     // the peer's reachable hostname or IP
    "port": 8377,
    "mac": "aa:bb:cc:dd:ee:ff"   // optional — enables Wake-on-LAN
  },
  "token": "shared-secret-string", // must match on both Macs; sent as X-DeskSwitch-Token
  "listenPort": 8377,
  "monitors": {
    "M27Q":    { "inputs": { "macmini": 15, "macbook": 17 } },
    "PA278CV": { "inputs": { "macmini": 17, "macbook": 15 } }
  },
  "preventSleepWhenHeadless": false,
  "wol": { "broadcastHost": "255.255.255.255", "port": 9 }
}
```

Fields other than `machineName`, `peer`, and `token` are optional and default sensibly (`listenPort` 8377, empty `monitors`, WoL disabled unless `peer.mac` is set). Missing `peer.mac` is a startup **warning**, not an error — the tool just degrades to retry-without-wake.

**Fill in the input codes with `probe`.** On each Mac, while it is displaying a monitor, run:

```bash
deskswitch probe    # records this Mac's input code for every monitor it currently drives
```

Then merge both machines' codes into both config files so every monitor has an entry for both machines. (A monitor can only be probed by the Mac that is currently showing it — switch inputs first if needed.)

## Usage

### CLI

```bash
deskswitch status                 # which Mac drives each monitor (local + peer)
deskswitch probe                  # record input codes for displays this Mac drives
deskswitch switch M27Q macbook    # send the M27Q to the MacBook
deskswitch switch M27Q macmini    # pull it back (forwards to the peer if needed)
deskswitch switch all macmini     # bring both monitors here
deskswitch serve                  # run the HTTP agent headless (the .app embeds this)
```

A switch prints `switched locally` or `forwarded to peer`, and exits non-zero with a readable message on failure (unknown monitor, missing input code, peer offline, DDC error).

### Menu bar

The app shows one row per configured monitor with its current owner ("here" vs. the peer name), refreshed when you open the menu. Row actions push a locally-driven monitor away or pull a peer-driven one here; convenience actions send or fetch both at once. Switch failures raise a macOS notification.

### HTTP API

Every agent (standalone `serve` or the app's embedded server) exposes:

```bash
# status
curl -H "X-DeskSwitch-Token: <token>" http://macmini.local:8377/status

# switch
curl -H "X-DeskSwitch-Token: <token>" -H 'Content-Type: application/json' \
     -d '{"monitor":"M27Q","target":"macmini"}' \
     http://macmini.local:8377/switch
```

A missing/incorrect token returns `401`; an unknown monitor returns `404`. The 2-second per-hop timeout means the UI never blocks. This makes it easy to trigger switches from an iPhone Shortcut, Stream Deck, or any HTTP client.

### Launch at login

Run from **inside the installed app bundle** (the LaunchAgent plist ships in it):

```bash
/Applications/DeskSwitch.app/Contents/MacOS/deskswitch autostart enable
/Applications/DeskSwitch.app/Contents/MacOS/deskswitch autostart status
/Applications/DeskSwitch.app/Contents/MacOS/deskswitch autostart disable
```

Approve the login item under System Settings → General → Login Items if prompted. KeepAlive restarts the app if it crashes or is killed, but leaves it quit if you quit it from the menu.

## Hardware notes

DDC/CI is finicky, and its reliability depends on **both the monitor and the connection type**. Things learned the hard way, worth knowing before you wire up:

- **One cable per Mac per monitor.** Connecting a single monitor to one Mac over two cables makes macOS enumerate it as two displays (a phantom) and confuses name-keyed discovery. Remove the redundant link.
- **Some links carry video but not DDC.** A connection can pass a picture while EDID reads succeed but VCP reads/writes silently fail — you'll see `I2C transfer failed`. Common culprits are certain HDMI ports on some monitors and non-video / adapter USB-C cables. If a link can't switch, move it to a different port (DisplayPort tends to be the most reliable) or use a proper Thunderbolt / DP-Alt-Mode cable.
- **Auto Input Detect can fight you.** Some monitors auto-jump back to a still-active source right after you switch away. If a monitor won't stay switched, disable "Auto Input Detect" / "Auto Source" in its OSD.
- **The tool never reads back a push**, so a monitor that ignores or reverts a DDC write does so silently. `deskswitch status` (which reads the live input) is the way to confirm where a monitor actually landed.

## Development

Pure logic is developed test-first; `swift test` is green before every commit. Hardware and UI layers get compile checks plus written verification checklists under `docs/verification/`.

```
Sources/DeskSwitchCore/   config, router, DDC + HTTP codecs, EDID, IOAVService engine, view-model, WoL, sleep guard
Sources/deskswitch/       CLI, SwiftUI MenuBarExtra app, notifier, entry point
Tests/DeskSwitchCoreTests/ unit tests + mocks for every pure component
docs/                     design spec, implementation plan, hardware verification checklists
packaging/                Info.plist + LaunchAgent plist
scripts/                  make-app.sh (bundle), e2e.sh (cross-machine HTTP test)
```

Run the full cross-machine end-to-end check (both agents running):

```bash
TOKEN=<token> MINI=macmini.local:8377 MBP=macbook.local:8377 scripts/e2e.sh
```

## License

Not yet licensed (all rights reserved). Add a `LICENSE` file if you want to allow reuse.
