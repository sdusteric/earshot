#!/bin/bash
# listen-power.sh <process name> [minutes]: Energy Impact and CPU of one
# process from powermetrics, one sample every 5 seconds. Needs sudo.
# Run it next to "earshot-probe listen" or the app with the wake word on.
# CPU is printed in ms/s and in percent of one core (ms/s / 10), the unit of the budgets.
name=${1:?process name, e.g. earshot-probe or Earshot}; mins=${2:-5}
n=$(( mins * 12 ))
sudo powermetrics --samplers tasks --show-process-energy -i 5000 -n "$n" 2>/dev/null \
  | awk -v name="$name" '
      # The header names the columns: "Name  ID  CPU ms/s ... Energy Impact". Columns are
      # found by these names, so a powermetrics release that moves them is caught.
      $1 == "Name" && / ID / {
        for (i = 1; i <= NF; i++) { if ($i == "ID") id = i; if ($i == "CPU" && $(i + 1) == "ms/s") cpu_at = i }
        if (!id || !cpu_at || $(NF - 1) != "Energy" || $NF != "Impact") { print "unexpected powermetrics header: " $0; bad = 1; exit 1 }
        cpu_off = cpu_at - id; header = 1; next
      }
      header {
        # A process name can have spaces: the ID is the first number after it.
        k = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) { k = i; break }
        if (!k) next
        proc = $1; for (i = 2; i < k; i++) proc = proc " " $i
        if (proc == name) { cpu += $(k + cpu_off); energy += $NF; samples++ }
      }
      END {
        if (bad) exit 1
        if (samples) printf "%s: %d samples, mean CPU %.1f ms/s (%.2f%% of one core), mean energy impact %.2f\n", name, samples, cpu / samples, cpu / samples / 10, energy / samples
        else print "no samples for " name
      }'
