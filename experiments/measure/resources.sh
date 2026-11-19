#!/bin/bash
# Passive sampler: once a minute, per machine, the CPU and memory of its cardano-node processes.
# Runs on your own machine (the Mac) and reads the VMs over ssh. Start it next to checkpoints.sh or
# forks.sh; it stops when all measurement scripts are gone or when $OUT/stop-resources exists.
#
# Usage:
#   OUT=results/growth-<date-time> ./resources.sh
#
# Environment (default):
#   OUT   result folder (required); the file is $OUT/resources.csv
#   VMS   the machines to sample   ("$POOL_HOST $VM2 $VM3 $VM4" from scripts/config.sh)
#
# Writes $OUT/resources.csv: time_utc,vm,nodes,cpu_pct,rss_mb,mem_available_mb,load1
# cpu_pct is the sum over the machine's cardano-node processes (100 = one full core).
cd "$(dirname "$0")"
source ../../scripts/config.sh                    # POOL_HOST, VM2, VM3, VM4

VMS=${VMS:-"$POOL_HOST $VM2 $VM3 $VM4"}
OUT=${OUT:?set OUT to the results folder}
CSV=$OUT/resources.csv
# the running measurement scripts (the [x] trick keeps pgrep from matching its own command line)
MEASUREMENT_SCRIPTS='[c]heckpoints.sh|[f]orks.sh|[r]un-all.sh|[a]symmetric.sh|[s]aturate.sh|[o]utsider.sh'
MEASUREMENT_SCRIPTS="$MEASUREMENT_SCRIPTS|[p]rofiles.sh|[g]ateways.sh|[n]ight5-queue"
[ -f "$CSV" ] || echo "time_utc,vm,nodes,cpu_pct,rss_mb,mem_available_mb,load1" > "$CSV"

# One sample of machine $1, as "<processes> <cpu %> <rss MB> <mem available MB> <load1>".
# The script in quotes runs on the VM: top reads the CPU over 5 s (second of two rounds), the rss column
# comes with a unit (m, g, or kB without a letter) that is turned into MB.
sample() {
  ssh -o BatchMode=yes "$1" '
    pids=$(pgrep -x cardano-node | paste -sd, -)
    if [ -n "$pids" ]; then
    top -b -n 2 -d 5 -w 200 -p "$pids" | awk '"'"'
      /^top -/ { n++ }
      n == 2 && $NF == "cardano-node" {
        c += $9; k++
        r = $6; if (r ~ /g$/) r = r * 1024; else if (r ~ /m$/) r += 0; else r = r / 1024
        m += r
      }
      END { printf "%d %.0f %.0f\n", k, c, m }'"'"'
    else echo "0 0 0"; fi
    echo "$(awk "/MemAvailable/{printf \"%d\", \$2/1024}" /proc/meminfo) $(cut -d" " -f1 /proc/loadavg)"
  ' 2>/dev/null
}

while [ ! -f "$OUT/stop-resources" ] && pgrep -f "$MEASUREMENT_SCRIPTS" > /dev/null; do
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for vm in $VMS; do
    ( set -- $(sample "$vm"); [ $# -eq 5 ] && echo "$now,$vm,$1,$2,$3,$4,$5" >> "$CSV" ) &
  done
  wait
  sleep 50
done
