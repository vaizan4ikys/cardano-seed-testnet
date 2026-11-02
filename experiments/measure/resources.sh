#!/bin/bash
# Passive sampler: once a minute, per machine, the CPU and memory of its cardano-node processes.
# Run it next to checkpoints.sh or forks.sh; it stops when all of them are gone or when $OUT/stop-resources exists.
#
#   OUT=results/growth-<date-time> ./resources.sh
#
# Writes $OUT/resources.csv: time_utc,vm,nodes,cpu_pct,rss_mb,mem_available_mb,load1
# cpu_pct is the sum over the machine's cardano-node processes (100 = one full core).
cd "$(dirname "$0")"
VMS=${VMS:-"seedvm seedvm2 seedvm3 seedvm4"}
OUT=${OUT:?set OUT to the results folder}
CSV=$OUT/resources.csv
[ -f "$CSV" ] || echo "time_utc,vm,nodes,cpu_pct,rss_mb,mem_available_mb,load1" > "$CSV"

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

while [ ! -f "$OUT/stop-resources" ] && pgrep -f "[c]heckpoints.sh|[f]orks.sh|[r]un-all.sh|[a]symmetric.sh|[s]aturate.sh|[o]utsider.sh|[p]rofiles.sh|[g]ateways.sh|[n]ight5-queue" > /dev/null; do
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for vm in $VMS; do
    ( set -- $(sample "$vm"); [ $# -eq 5 ] && echo "$now,$vm,$1,$2,$3,$4,$5" >> "$CSV" ) &
  done
  wait
  sleep 50
done
