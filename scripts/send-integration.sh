#!/bin/bash
# send-integration.sh: a real background session gets a prompt through the
# Dispatcher and answers it. Uses a little Claude usage. Terminal and desktop
# sessions are checked by hand (tests/app-e2e.md).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v jq >/dev/null || { echo "jq is required (brew install jq)"; exit 1; }
cd "$ROOT" || exit 1
ids() { claude agents --json | jq -r --arg cwd "$ROOT" '.[] | select(.kind == "background" and .cwd == $cwd) | .sessionId'; }
before=$(ids)
claude --bg "Wait for the next message." >/dev/null || { echo "couldn't start a background session"; exit 1; }
sleep 8
id=$(comm -13 <(echo "$before" | sort) <(ids | sort) | tail -1)
[ -n "$id" ] || { echo "no new background session found"; exit 1; }
trap 'claude stop "$id" >/dev/null 2>&1' EXIT
token="EARSHOT-$RANDOM"
swift run --package-path "$ROOT/app/EarshotKit" -c release earshot-probe send-id "$id" "Reply with exactly $token and nothing else." || exit 1
sleep 20
if claude logs "$id" 2>/dev/null | grep -q "$token"; then echo "ok: the background session answered"; exit 0
else echo "FAIL: no answer with $token in claude logs $id"; exit 1; fi
