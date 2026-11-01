#!/bin/bash
# Many nodes on one pool: what does it cost the pool, and do the nodes still get blocks fast?
# Run from your own machine over SSH; keep ../load running so that the blocks are full.
#
#   ./fanout.sh                              COUNTS="1 4 8 12", 300 s of samples each
#   COUNTS="1 6" WINDOW=120 ./fanout.sh
#
# N nodes (spread over seedvm2, seedvm3 and seedvm4, named fan1..fanN) all dial pool 1 directly. When they
# have joined: WINDOW seconds of block arrival times at every node (median per node, then the median and the
# worst 95th percentile over all nodes), the bytes pool 1 sent and received, and the CPU time its node used.
# Output: results/fanout-<date-time>/fanout.csv
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
POOL=${POOL:-seedvm}
COUNTS=${COUNTS:-"1 4 8 12"}
WINDOW=${WINDOW:-300}
REPO=cardano-seed-testnet
VMS=(seedvm2 seedvm3 seedvm4)
OUT=${OUT:-$HERE/results/fanout-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT/logs"
on() { local vm=$1; shift; ssh -A -o BatchMode=yes "$vm" "cd $REPO && $*" 2> >(grep -v '^\*\*' >&2); }
ip_of() { ssh -o BatchMode=yes "$1" hostname -I 2>/dev/null | cut -d' ' -f1; }
MAXN=$(echo $COUNTS | tr ' ' '\n' | sort -n | tail -1)
stop_all() { for vm in "${VMS[@]}"; do on "$vm" 'docker rm -f $(docker ps -aq --filter name=fan) >/dev/null 2>&1; true' >/dev/null 2>&1 || true; done; }
trap stop_all EXIT
POOL_IP=$(ip_of "$POOL")
# "<rx bytes> <tx bytes> <node cpu ticks>" of pool 1
pool_stats() { ssh -A -o BatchMode=yes "$POOL" "cd $REPO && source scripts/lib.sh && docker exec -i \$(pool_container 1) bash -s" < "$HERE/in-container/netcpu.sh" 2> >(grep -v '^\*\*' >&2); }
echo "nodes,blocks,median_of_medians_ms,worst_p95_ms,pool1_rx_mb_per_hour,pool1_tx_mb_per_hour,pool1_cpu_percent" > "$OUT/fanout.csv"
echo "date: $(date -u +%FT%TZ)    counts: $COUNTS    window: $WINDOW s" | tee "$OUT/setup.txt"
for vm in "${VMS[@]}"; do on "$vm" "./experiments/join-node/fetch-chain-files.sh seed@$POOL_IP" >/dev/null; done
stop_all

for n in $COUNTS; do
  echo "== $n nodes on pool 1"
  stop_all
  for k in $(seq "$n"); do
    vm=${VMS[$(( (k - 1) % 3 ))]}
    on "$vm" "NAME=fan$k TIMEOUT=600 ./experiments/measure/sync-time.sh $POOL_IP 3001" >/dev/null || echo "  fan$k did not sync"
  done
  AFTER=$(date -u +%Y-%m-%dT%H:%M:%S)
  read -r r0 t0 c0 <<< "$(pool_stats)"; s0=$(date +%s)
  sleep "$WINDOW"
  read -r r1 t1 c1 <<< "$(pool_stats)"; s1=$(date +%s)
  LOGS="$OUT/logs/n$n"; mkdir -p "$LOGS"
  for p in 1 2 3; do on "$POOL" "source scripts/lib.sh && docker exec \$(pool_container $p) cat /var/log/cardano-node.log" > "$LOGS/pool$p.log"; done
  OFFSETS=$(python3 -I "$HERE/clock-offsets.py" "$POOL" "${VMS[@]}")
  offset() { awk -F, -v m="$1" '$1 == m { print $2 }' <<< "$OFFSETS"; }
  args=(pool1="$LOGS/pool1.log@$(offset "$POOL")" pool2="$LOGS/pool2.log@$(offset "$POOL")" pool3="$LOGS/pool3.log@$(offset "$POOL")")
  for k in $(seq "$n"); do
    vm=${VMS[$(( (k - 1) % 3 ))]}
    ssh -o BatchMode=yes "$vm" "docker logs fan$k 2>&1" > "$LOGS/fan$k.log" 2>/dev/null
    args+=("fan$k=$LOGS/fan$k.log@$(offset "$vm")")
  done
  python3 -I "$HERE/propagation.py" --after "$AFTER" "${args[@]}" 2>/dev/null | grep '^fan' > "$LOGS/propagation.csv" || true
  python3 - "$n" $((s1 - s0)) $((r1 - r0)) $((t1 - t0)) $((c1 - c0)) "$LOGS/propagation.csv" <<'PY' | tee -a "$OUT/fanout.csv"
import csv, statistics, sys
n, w, rx, tx, cpu, f = sys.argv[1:]
rows = [r for r in csv.reader(open(f)) if r]
blocks = max(int(r[1]) for r in rows); med = statistics.median(float(r[2]) for r in rows); worst = max(float(r[3]) for r in rows)
print("%s,%d,%.0f,%.0f,%.1f,%.1f,%.1f" % (n, blocks, med, worst, int(rx) / 1048576 * 3600 / int(w), int(tx) / 1048576 * 3600 / int(w), int(cpu) / 100 / int(w) * 100))
PY
done
stop_all; trap - EXIT
echo "done: $OUT"
