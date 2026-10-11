#!/bin/bash
# latency.sh [hours]: p50 and p95 from the end of a command to the start of
# Earshot's answer, from the app's log. Bar: p50 under 1000 ms, p95 under 1500 ms over 20 hotkey commands.
h=${1:-2}
log show --last "${h}h" --style compact --predicate 'subsystem == "com.earshot.app" AND category == "latency"' 2>/dev/null \
  | grep -oE 'latency [0-9]+ ms' | awk '{print $2}' | sort -n \
  | awk '{ v[NR] = $1 } END { if (NR == 0) { print "no commands logged"; exit 1 }
          p50 = v[int((NR - 1) * 0.5) + 1]; p95 = v[int((NR - 1) * 0.95) + 1]
          printf "%d commands: p50 %d ms, p95 %d ms\n", NR, p50, p95 }'
