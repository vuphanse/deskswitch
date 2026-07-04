# M4 Verification — Polish (autostart, WoL, notifications, flip-both, sleep)

Prerequisite: M3 checklist passed; rebuilt bundle (scripts/make-app.sh) installed in
/Applications on both Macs.

## Autostart
- [ ] `/Applications/DeskSwitch.app/Contents/MacOS/deskswitch autostart enable` on both Macs
      (approve in System Settings > General > Login Items if prompted)
- [ ] Log out / in: menu bar icon appears without manual launch
- [ ] `kill -9 <pid>` the running deskswitch: launchd restarts it within seconds (KeepAlive)

## Flip both
- [ ] Menu "Send both away" flips both monitors to the peer in one action
- [ ] Menu "Bring both here" pulls both back (forward path)
- [ ] `deskswitch switch all <machine>` does the same from the CLI, reporting per-monitor results

## Notifications
- [ ] Quit the peer app, try a pull from the menu: macOS notification "other Mac offline"
      appears (grant notification permission on first run)
- [ ] Unplug-simulate a DDC failure is impractical — instead verify the notification path
      with the peer-offline case above (same code path via MenuState/Notifier)

## Wake-on-LAN (requires "Wake for network access" ON in System Settings > Energy/Battery
on BOTH Macs; MacBook additionally on power for reliable wake)
- [ ] Confirm `peer.mac` in each config matches the OTHER Mac's active interface MAC
      (`ifconfig en0 | grep ether`)
- [ ] Put the MacBook to sleep, from the mini run `deskswitch switch all macmini` twice if
      needed: magic packet + retry completes the pull (allow one wake cycle ~3-10 s)
- [ ] Remove `peer.mac` from the mini's config temporarily: same action skips the magic
      packet but still retries once — fails with `other Mac offline` after ~4-5 s (two 2 s
      attempts + brief backoff) with a startup warning logged — restore `peer.mac` after
- [ ] Clamshell check (spec risk): repeat the sleep test with the MacBook lid closed

## Headless sleep prevention
- [ ] Set `"preventSleepWhenHeadless": true` on the Mac mini; push both monitors away;
      within ~1 min `pmset -g assertions` on the mini lists PreventSystemSleep from deskswitch
- [ ] Pull a monitor back; within ~1 min the assertion is released
- [ ] Full E2E: TOKEN=<secret> scripts/e2e.sh passes with both Macs on the final build
