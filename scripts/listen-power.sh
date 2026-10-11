#!/bin/bash
# listen-power.sh <process name> [minutes]: Energy Impact and CPU of one
# process from powermetrics, one sample every 5 seconds. Needs sudo.
# Run it next to "earshot-probe listen" or the app with the wake word on.
name=${1:?process name, e.g. earshot-probe or Earshot}; mins=${2:-5}
n=$(( mins * 12 ))
sudo powermetrics --samplers tasks --show-process-energy -i 5000 -n "$n" 2>/dev/null \
  | awk -v name="$name" '
      $0 ~ name { cpu += $3; energy += $NF; samples++ }
      END { if (samples) printf "%s: %d samples, mean CPU %.1f ms/s, mean energy impact %.2f\n", name, samples, cpu / samples, energy / samples
            else print "no samples for " name }'
