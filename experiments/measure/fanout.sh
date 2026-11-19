#!/bin/bash
# Many nodes on one pool: what does it cost the pool, and do the nodes still get blocks fast?
# Runs on your own machine (the Mac) and drives the VMs over ssh; keep ../load running so that the blocks
# are full.
#
# Usage:
#   ./fanout.sh                              COUNTS="1 4 8 12", 300 s of samples each
#   COUNTS="1 6" WINDOW=120 ./fanout.sh
#
# Environment (default):
#   POOL    the VM that runs the pools                       (POOL_HOST from scripts/config.sh)
#   COUNTS  numbers of nodes to try, one series each         ("1 4 8 12")
#   WINDOW  seconds of block arrival samples per series      (300)
#   OUT     result folder                                    (results/fanout-<date-time> next to this script)
#   The nodes are spread over VM2, VM3 and VM4 (scripts/config.sh; seedvm2, seedvm3, seedvm4 in our lab).
#
# N nodes (named fan1..fanN) all dial pool 1 directly. When they have joined: WINDOW seconds of block
# arrival times at every node (median per node, then the median and the worst 95th percentile over all
# nodes), the bytes pool 1 sent and received, and the CPU time its node used.
# Output: results/fanout-<date-time>/fanout.csv
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../../scripts/config.sh"            # POOL_HOST, VM2, VM3, VM4, REPO

POOL=${POOL:-$POOL_HOST}
COUNTS=${COUNTS:-"1 4 8 12"}
WINDOW=${WINDOW:-300}
VMS=("$VM2" "$VM3" "$VM4")                        # node k runs on VMS[(k-1) % 3]
OUT=${OUT:-$HERE/results/fanout-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT/logs"

# --- helpers (every ssh call hides the "**" banner lines of the VM) ---

# run a command in the repository folder on a VM ("-A": the VM may need your key to reach the pool)
on() { local vm=$1; shift; ssh -A -o BatchMode=yes "$vm" "cd $REPO && $*" 2> >(grep -v '^\*\*' >&2); }

# first IP address of a VM
ip_of() { ssh -o BatchMode=yes "$1" hostname -I 2>/dev/null | cut -d' ' -f1; }

# the node log of pool $1 (1, 2 or 3)
pool_log() { on "$POOL" "source scripts/lib.sh && docker exec \$(pool_container $1) cat /var/log/cardano-node.log"; }

# remove all fan nodes from all VMs
stop_all() {
  for vm in "${VMS[@]}"; do
    on "$vm" 'docker rm -f $(docker ps -aq --filter name=fan) >/dev/null 2>&1; true' >/dev/null 2>&1 || true
  done
}

# "<rx bytes> <tx bytes> <node cpu ticks>" of pool 1 (in-container/netcpu.sh runs inside its container)
pool_stats() {
  ssh -A -o BatchMode=yes "$POOL" "cd $REPO && source scripts/lib.sh && docker exec -i \$(pool_container 1) bash -s" \
    < "$HERE/in-container/netcpu.sh" 2> >(grep -v '^\*\*' >&2)
}

trap stop_all EXIT
POOL_IP=$(ip_of "$POOL")
echo "nodes,blocks,median_of_medians_ms,worst_p95_ms,pool1_rx_mb_per_hour,pool1_tx_mb_per_hour,pool1_cpu_percent" \
  > "$OUT/fanout.csv"
echo "date: $(date -u +%FT%TZ)    counts: $COUNTS    window: $WINDOW s" | tee "$OUT/setup.txt"
for vm in "${VMS[@]}"; do on "$vm" "./experiments/join-node/fetch-chain-files.sh seed@$POOL_IP" >/dev/null; done
stop_all

for n in $COUNTS; do
  echo "== $n nodes on pool 1"
  stop_all
  for k in $(seq "$n"); do
    vm=${VMS[$(( (k - 1) % 3 ))]}
    on "$vm" "NAME=fan$k TIMEOUT=600 ./experiments/measure/sync-time.sh $POOL_IP 3001" >/dev/null \
      || echo "  fan$k did not sync"
  done

  # bytes and CPU of pool 1 over the window
  AFTER=$(date -u +%Y-%m-%dT%H:%M:%S)
  read -r r0 t0 c0 <<< "$(pool_stats)"; s0=$(date +%s)
  sleep "$WINDOW"
  read -r r1 t1 c1 <<< "$(pool_stats)"; s1=$(date +%s)

  # the logs of the pools and of every fan node, on one timeline
  LOGS="$OUT/logs/n$n"; mkdir -p "$LOGS"
  for p in 1 2 3; do pool_log $p > "$LOGS/pool$p.log"; done
  OFFSETS=$(python3 -I "$HERE/clock-offsets.py" "$POOL" "${VMS[@]}")
  offset() { awk -F, -v m="$1" '$1 == m { print $2 }' <<< "$OFFSETS"; }
  args=(pool1="$LOGS/pool1.log@$(offset "$POOL")" pool2="$LOGS/pool2.log@$(offset "$POOL")"
        pool3="$LOGS/pool3.log@$(offset "$POOL")")
  for k in $(seq "$n"); do
    vm=${VMS[$(( (k - 1) % 3 ))]}
    ssh -o BatchMode=yes "$vm" "docker logs fan$k 2>&1" > "$LOGS/fan$k.log" 2>/dev/null
    args+=("fan$k=$LOGS/fan$k.log@$(offset "$vm")")
  done
  python3 -I "$HERE/propagation.py" --after "$AFTER" "${args[@]}" 2>/dev/null | grep '^fan' > "$LOGS/propagation.csv" || true

  # one row: nodes, blocks, median of the node medians, worst p95, pool 1 traffic (MB/hour) and CPU (%)
  python3 - "$n" $((s1 - s0)) $((r1 - r0)) $((t1 - t0)) $((c1 - c0)) "$LOGS/propagation.csv" <<'PY' | tee -a "$OUT/fanout.csv"
import csv, statistics, sys
n, window, rx, tx, cpu, propagation_csv = sys.argv[1:]
rows = [r for r in csv.reader(open(propagation_csv)) if r]   # node,blocks,median_ms,p95_ms,max_ms
blocks = max(int(r[1]) for r in rows)
median_of_medians = statistics.median(float(r[2]) for r in rows)
worst_p95 = max(float(r[3]) for r in rows)
w = int(window)
rx_mb_per_hour = int(rx) / 1048576 * 3600 / w
tx_mb_per_hour = int(tx) / 1048576 * 3600 / w
cpu_percent = int(cpu) / 100 / w * 100                       # ticks: 100 = one CPU second
print("%s,%d,%.0f,%.0f,%.1f,%.1f,%.1f" % (n, blocks, median_of_medians, worst_p95, rx_mb_per_hour, tx_mb_per_hour, cpu_percent))
PY
done
stop_all; trap - EXIT
echo "done: $OUT"
