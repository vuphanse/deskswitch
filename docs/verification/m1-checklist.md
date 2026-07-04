# M1 Hardware Verification — DDC core + CLI

Prerequisite: create `~/.config/deskswitch/config.json` on each Mac (see spec §Config;
`monitors` may start empty — probe fills it). Run every step on BOTH Macs unless noted.

- [ ] `swift run deskswitch status` lists the monitor(s) this Mac drives, named `M27Q` / `PA278CV`
- [ ] `swift run deskswitch probe` prints recorded codes and writes them into config
- [ ] Verify probed codes appear in `~/.config/deskswitch/config.json` under this machine's name
- [ ] After probing on both Macs, merge both machines' codes into BOTH config files (each
      file needs the full `inputs` map per monitor)
- [ ] Push: `swift run deskswitch switch M27Q <other-machine>` flips that monitor away;
      command prints `switched locally` and exits 0 (display disappearing = success)
- [ ] Repeat push for `PA278CV`
- [ ] `swift run deskswitch switch M27Q <this-machine>` while the monitor is elsewhere
      prints `other Mac offline` (M1 has no forwarding yet) and exits 1
- [ ] `swift run deskswitch switch M27Q nobody` errors mentioning `deskswitch probe`
- [ ] M27Q flakiness check (spec risk): if probe/switch misbehaves, note the cable path;
      re-cable that machine to DisplayPort/USB-C and retest
