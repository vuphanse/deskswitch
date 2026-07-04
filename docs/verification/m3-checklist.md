# M3 Verification — Menu bar UI

Prerequisite: M2 checklist passed. Build with `scripts/make-app.sh`, copy
`build/DeskSwitch.app` to /Applications on both Macs, launch on both.

- [ ] Menu bar shows the display icon; NO Dock icon appears (LSUIElement)
- [ ] Opening the menu shows one row per configured monitor with correct owner
      ("here" vs peer name) — refreshed on open, spec: no background polling
- [ ] Row action on a locally-driven monitor pushes it away; monitor flips, menu row
      updates on next open
- [ ] Row action on a peer-driven monitor pulls it here (forward path through peer agent)
- [ ] With the peer app quit, menu shows "<peer> unreachable" and pull actions surface
      "other Mac offline" without hanging the UI (2 s budget, background refresh)
- [ ] The embedded HTTP agent works: e2e.sh passes while only the .app (no `serve`) runs
- [ ] `deskswitch status` from the terminal still works while the app runs
      (CLI dispatch unaffected)
