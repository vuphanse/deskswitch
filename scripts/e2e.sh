#!/bin/bash
# End-to-end verification: run from either Mac with BOTH agents serving.
# Usage: TOKEN=<shared-secret> [MINI=host:port] [MBP=host:port] scripts/e2e.sh
set -euo pipefail

MINI="${MINI:-macmini.local:8377}"
MBP="${MBP:-macbook.local:8377}"
TOKEN="${TOKEN:?set TOKEN to the shared secret}"
AUTH="X-DeskSwitch-Token: $TOKEN"

step() { printf '\n== %s\n' "$*"; }
post() { curl -sf -m 5 -H "$AUTH" -H 'Content-Type: application/json' -d "$2" "http://$1/switch"; echo; }
status() { curl -sf -m 5 -H "$AUTH" "http://$1/status"; echo; }

step "status: both agents answer"
status "$MINI"
status "$MBP"

step "push/pull both monitors to macmini (router forwards if needed)"
post "$MINI" '{"monitor":"M27Q","target":"macmini"}'
post "$MINI" '{"monitor":"PA278CV","target":"macmini"}'

step "pull both monitors to macbook via the mini (forward path)"
post "$MINI" '{"monitor":"M27Q","target":"macbook"}'
post "$MINI" '{"monitor":"PA278CV","target":"macbook"}'

step "flip both back to macmini via the macbook agent"
post "$MBP" '{"monitor":"M27Q","target":"macmini"}'
post "$MBP" '{"monitor":"PA278CV","target":"macmini"}'

step "bad token is rejected with 401"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "X-DeskSwitch-Token: wrong" "http://$MINI/status")
[ "$code" = "401" ] && echo "OK (401)" || { echo "FAIL: got $code"; exit 1; }

step "unknown monitor is rejected with 404"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "$AUTH" -H 'Content-Type: application/json' \
    -d '{"monitor":"LG99","target":"macmini"}' "http://$MINI/switch")
[ "$code" = "404" ] && echo "OK (404)" || { echo "FAIL: got $code"; exit 1; }

echo
echo "E2E complete — verify visually that both monitors ended on macmini."
