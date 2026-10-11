#!/bin/bash
# send-integration.sh: a real background session gets a prompt through the
# Dispatcher and answers it. Uses a little Claude usage. Terminal and desktop
# sessions are checked by hand (tests/app-e2e.md).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="swift run --package-path $ROOT/app/EarshotKit -c release earshot-probe"
cd "$ROOT" || exit 1
claude --bg "Wait for the next message." >/dev/null || { echo "couldn't start a background session"; exit 1; }
sleep 8
id=$(claude agents --json | jq -r --arg cwd "$ROOT" '[.[] | select(.kind == "background" and .cwd == $cwd)] | last | .sessionId')
[ -n "$id" ] && [ "$id" != null ] || { echo "no background session found"; exit 1; }
token="EARSHOT-$RANDOM"
$P send earshot "Reply with exactly $token and nothing else."
sleep 20
if claude logs "$id" 2>/dev/null | grep -q "$token"; then echo "ok: the background session answered"; r=0
else echo "FAIL: no answer with $token in claude logs $id"; r=1; fi
claude stop "$id" >/dev/null 2>&1
exit $r
