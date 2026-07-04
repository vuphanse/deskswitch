# M2 Verification — HTTP API + router

Prerequisite: M1 checklist passed on both Macs; both configs hold full input maps;
`deskswitch serve` (or `swift run deskswitch serve`) running on BOTH Macs.

- [ ] `TOKEN=<secret> scripts/e2e.sh` passes end to end from the Mac mini
- [ ] `TOKEN=<secret> scripts/e2e.sh` passes end to end from the MacBook
- [ ] Pull flow works from the CLI: `deskswitch switch M27Q <this-machine>` on the Mac
      that does NOT drive M27Q prints `forwarded to peer` and the monitor appears here
- [ ] Stop the peer agent, run `deskswitch switch <monitor-driven-by-peer> <this-machine>`:
      fails with `other Mac offline` in ~2-4 s (2 s budget/hop; WoL retry arrives in M4)
- [ ] `deskswitch status` shows both machines' monitors when both agents run
- [ ] Topology refresh: with both agents left RUNNING (no restarts), push a monitor away
      and pull it back; `status` on both Macs reflects each move, and the pull succeeds on
      the Mac that started headless (the engine re-enumerates displays per operation)
- [ ] iPhone Shortcut (optional preview): "Get Contents of URL" POST to
      http://macmini.local:8377/switch with the token header flips a monitor
