#!/bin/bash
# send-integration.sh: a real background session gets a prompt through the
# Dispatcher and answers it. Uses a little Claude usage. Terminal and desktop
# sessions are checked by hand (tests/app-e2e.md).
set -o pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v jq >/dev/null || { echo "jq is required (brew install jq)"; exit 1; }
cd "$ROOT" || exit 1
# The background sessions in this folder. Fails unless claude agents answered with a JSON list.
ids() {
  local json
  json=$(claude agents --json) || return 1
  jq -e 'type == "array"' >/dev/null <<<"$json" || return 1
  jq -r --arg cwd "$ROOT" '.[] | select(.kind == "background" and .cwd == $cwd) | .sessionId' <<<"$json"
}
# Without the list of sessions from before, one of yours could look new and be stopped.
before=$(ids) || { echo "claude agents --json failed or did not return a list; started nothing"; exit 1; }
claude --bg "Wait for the next message." >/dev/null || { echo "couldn't start a background session"; exit 1; }
sleep 8
after=$(ids) || { echo "claude agents --json failed after the start; stop the new session by hand (claude agents)"; exit 1; }
id=$(comm -13 <(echo "$before" | sort) <(echo "$after" | sort) | tail -1)
[ -n "$id" ] || { echo "no new background session found"; exit 1; }
trap 'claude stop "$id" >/dev/null 2>&1' EXIT
token="KOBI-$RANDOM"
swift run --package-path "$ROOT/app/KobiKit" -c release kobi-probe send-id "$id" "Reply with exactly $token and nothing else." || exit 1
sleep 20
logs=$(claude logs "$id" 2>/dev/null)
if grep -q "$token" <<<"$logs"; then echo "ok: the background session answered"; exit 0
else echo "FAIL: no answer with $token in claude logs $id"; exit 1; fi
