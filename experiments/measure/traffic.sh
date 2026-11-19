#!/bin/bash
# Network traffic in normal operation: how many bytes does a node send and receive when it is NOT joining?
# Runs on your own machine (the Mac) and drives the VMs over ssh.
#
# Usage:
#   ./traffic.sh                            WINDOW=600 s per scenario, scenarios: idle and full
#   WINDOW=300 SCENARIOS="idle" ./traffic.sh
#
# Environment (default):
#   POOL       the VM that runs the pools                 (POOL_HOST from scripts/config.sh)
#   HOP1       joiner that dials the pools                (VM2 from scripts/config.sh)
#   HOP2       joiner that dials HOP1                     (VM4 from scripts/config.sh)
#   WINDOW     seconds of counting per scenario           (600)
#   SCENARIOS  "idle", "full" or both                     ("idle full")
#   OUT        result folder                              (results/traffic-<date-time> next to this script)
#
# Nodes: pool 1 (counter of its net0), hop 1 and hop 2 behind it, as in the other tests.
# Scenarios: idle = the load is off, the blocks are empty; full = ../load keeps every block full (the chain
# works at its limit). The bytes of each node's network card are read at the start and at the end of the
# window (/proc/net/dev inside the container). Output: results/traffic-<date-time>/traffic.csv
# (scenario,node,window_s,blocks,rx_mb,tx_mb,rx_mb_per_hour,tx_mb_per_hour,rx_gb_per_day,tx_gb_per_day)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../../scripts/config.sh"            # POOL_HOST, VM2, VM4, REPO

POOL=${POOL:-$POOL_HOST}; HOP1=${HOP1:-$VM2}; HOP2=${HOP2:-$VM4}
WINDOW=${WINDOW:-600}
SCENARIOS=${SCENARIOS:-"idle full"}
OUT=${OUT:-$HERE/results/traffic-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"

# --- helpers (every ssh call hides the "**" banner lines of the VM) ---

# run a command in the repository folder on a VM ("-A": the VM may need your key to reach the pool)
on() { local vm=$1; shift; ssh -A -o BatchMode=yes "$vm" "cd $REPO && $*" 2> >(grep -v '^\*\*' >&2); }

# first IP address of a VM
ip_of() { ssh -o BatchMode=yes "$1" hostname -I 2>/dev/null | cut -d' ' -f1; }

# remove the joiners of both hops
cleanup() { for vm in "$HOP2" "$HOP1"; do on "$vm" "./experiments/join-node/join.sh stop" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

# "<rx bytes> <tx bytes>" of the network card of a node (pool1, hop1 or hop2)
counters() {   # node
  case $1 in
    pool1) on "$POOL" 'source scripts/lib.sh && docker exec $(pool_container 1) cat /proc/net/dev' ;;
    hop1)  on "$HOP1" 'docker exec cardano-joiner cat /proc/net/dev' ;;
    hop2)  on "$HOP2" 'docker exec cardano-joiner cat /proc/net/dev' ;;
  esac | awk '$1 ~ /^(eth0|net0):/ { sub(/^[a-z0-9]+:/, "", $1); if ($1 == "") print $2, $10; else print $1, $9 }'
}

# block number of pool 1's tip
tip() { on "$POOL" 'source scripts/lib.sh && tip_of 1' | grep -o '"block": *[0-9]*' | grep -o '[0-9]*$'; }

# wait (up to 5 minutes) until pool 1's mempool is empty
wait_for_empty_mempool() {
  local m
  for _ in $(seq 60); do
    m=$(on "$POOL" 'source scripts/lib.sh && docker exec $(pool_container 1) cardano-cli conway query tx-mempool info \
                      --socket-path /node.socket --testnet-magic $MAGIC' | jq -r .numberOfTxs)
    [ "$m" = 0 ] && break
    sleep 5
  done
}

POOL_IP=$(ip_of "$POOL"); HOP1_IP=$(ip_of "$HOP1")
echo "scenario,node,window_s,blocks,rx_mb,tx_mb,rx_mb_per_hour,tx_mb_per_hour,rx_gb_per_day,tx_gb_per_day" > "$OUT/traffic.csv"
{
  echo "date: $(date -u +%FT%TZ)    window: $WINDOW s    scenarios: $SCENARIOS"
  echo "chain at start: $(on "$POOL" 'source scripts/lib.sh && tip_of 1')"
} | tee "$OUT/setup.txt"
for vm in "$HOP1" "$HOP2"; do on "$vm" "./experiments/join-node/fetch-chain-files.sh seed@$POOL_IP" >/dev/null; done
cleanup
on "$HOP1" "LISTEN=1 ./experiments/measure/sync-time.sh $POOL_IP" >/dev/null
on "$HOP2" "./experiments/measure/sync-time.sh $HOP1_IP" >/dev/null
echo "hop 1 and hop 2 are synced"

for scenario in $SCENARIOS; do
  if [ "$scenario" = idle ]; then
    on "$POOL" './experiments/load/load.sh stop' >/dev/null || true
    wait_for_empty_mempool
    sleep 60
  else
    on "$POOL" './experiments/load/load.sh start' >/dev/null || true
    sleep 120
  fi
  echo "== $scenario: $WINDOW s"

  # counters at the start of the window (R0_<node> = rx bytes, T0_<node> = tx bytes) ...
  B0=$(tip); T0=$(date +%s)
  for n in pool1 hop1 hop2; do read -r r t <<< "$(counters $n)"; eval "R0_$n=$r T0_$n=$t"; done
  sleep "$WINDOW"
  # ... and at the end, then one row per node with the differences
  B1=$(tip); T1=$(date +%s)
  for n in pool1 hop1 hop2; do
    read -r r t <<< "$(counters $n)"; r0=R0_$n; t0=T0_$n
    awk -v sc="$scenario" -v n="$n" -v w=$((T1 - T0)) -v b=$((B1 - B0)) -v r=$((r - ${!r0})) -v t=$((t - ${!t0})) '
      BEGIN { rm = r / 1048576; tm = t / 1048576
              printf "%s,%s,%d,%d,%.1f,%.1f,%.1f,%.1f,%.2f,%.2f\n", sc, n, w, b, rm, tm,
                     rm * 3600 / w, tm * 3600 / w, rm * 86400 / w / 1024, tm * 86400 / w / 1024 }' | tee -a "$OUT/traffic.csv"
  done
done
cleanup; trap - EXIT
echo "done: $OUT"
