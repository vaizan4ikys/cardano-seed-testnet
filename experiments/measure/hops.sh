#!/bin/bash
# A chain of nodes behind a pool: how do join time, block arrival and transaction latency grow with the
# number of hops? Runs on your own machine (the Mac) and drives the VMs over ssh, like run-all.sh.
#
# Usage:
#   ./hops.sh                                    HOPS=3, DELAYS="0 50 100"
#   HOPS=6 DELAYS="0 100" IDLE=300 ./hops.sh
#   JOIN_ONLY=1 REPS=3 ./hops.sh                 only the join times, three times
#
# Environment (default):
#   POOL       the VM that runs the pools                       (POOL_HOST from scripts/config.sh)
#   HOPS       number of nodes in the chain, 1 to 6             (3)
#   DELAYS     ms added to what each node sends, one series each ("0 50 100")
#   IDLE       seconds of block samples per delay               (420)
#   REPS       repetitions of the whole series                  (1)
#   JOIN_ONLY  1 = only the join times (no block samples, no transactions)   (unset)
#   TXS        transactions per measured node and delay (one more, not recorded, comes first)   (6)
#   OUT        result folder                                    (results/hops-<date-time> next to this script)
#
# Node k dials node k-1 (node 1 dials pool 1). The nodes sit on three machines (VM2, VM4, VM3 of
# scripts/config.sh = seedvm2, seedvm4, seedvm3 in our lab); from hop 4 on a machine hosts a second node
# (own container name and port), so a chain of 6 needs only three VMs:
#   hop1 VM2:3001   hop2 VM4:3001   hop3 VM3:3001
#   hop4 VM2:3002   hop5 VM4:3002   hop6 VM3:3002
# Every node gets the delay on what it sends, so beyond the first link the delay acts in both directions
# of a link (data one way, requests the other); the first link, pool to hop 1, is delayed on one side only.
# Per delay: the nodes join one after the other (join time and MB received per hop), then IDLE seconds of
# block arrival samples (keep ../load running so that blocks are full), then transactions at hop 1 and at
# the last hop. Output in results/hops-<date-time>/: join.csv, propagation.csv, tx.csv.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../../scripts/config.sh"            # POOL_HOST, VM2, VM3, VM4, REPO

POOL=${POOL:-$POOL_HOST}
HOPS=${HOPS:-3}
DELAYS=${DELAYS:-"0 50 100"}
IDLE=${IDLE:-420}                        # seconds of block samples per delay
REPS=${REPS:-1}                           # repetitions of the whole series
JOIN_ONLY=${JOIN_ONLY:-}                 # 1: only the join times (no block samples, no transactions)
TXS=${TXS:-6}                            # transactions per measured node and delay (one more, not recorded, comes first)
OUT=${OUT:-$HERE/results/hops-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT/logs"

VMS=("$VM2" "$VM4" "$VM3" "$VM2" "$VM4" "$VM3")               # machine of hop 1..6
PORTS=(3001 3001 3001 3002 3002 3002)                         # port the node publishes on that machine

# --- helpers (every ssh call hides the "**" banner lines of the VM) ---

# run a command in the repository folder on a VM ("-A": the VM may need your key to reach the pool)
on() { local vm=$1; shift; ssh -A -o BatchMode=yes "$vm" "cd $REPO && $*" 2> >(grep -v '^\*\*' >&2); }

# first IP address of a VM
ip_of() { ssh -o BatchMode=yes "$1" hostname -I 2>/dev/null | cut -d' ' -f1; }

# the node log of pool $1 (1, 2 or 3)
pool_log() { on "$POOL" "source scripts/lib.sh && docker exec \$(pool_container $1) cat /var/log/cardano-node.log"; }

# remove the nodes of all hops
stop_all() {
  for k in $(seq "$HOPS" -1 1); do on "${VMS[$((k - 1))]}" "docker rm -f hop$k" >/dev/null 2>&1 || true; done
}
trap stop_all EXIT

POOL_IP=$(ip_of "$POOL")
echo "rep,delay_ms,hop,machine,join_seconds,blocks,db_kb,received_mb" > "$OUT/join.csv"
echo "delay_ms,hop,blocks,median_ms,p95_ms,max_ms" > "$OUT/propagation.csv"
echo "delay_ms,hop,block_seconds,mempool_seconds" > "$OUT/tx.csv"
: > "$OUT/blockrate.txt"
{
  echo "date: $(date -u +%FT%TZ)    hops: $HOPS    delays: $DELAYS    idle: $IDLE s"
  echo "chain at start: $(on "$POOL" 'source scripts/lib.sh && tip_of 1')"
  echo "load: $(on "$POOL" './experiments/load/load.sh status' | head -1)"
} | tee "$OUT/setup.txt"

for vm in "$VM2" "$VM4" "$VM3"; do on "$vm" "./experiments/join-node/fetch-chain-files.sh seed@$POOL_IP" >/dev/null; done
stop_all

for rep in $(seq "$REPS"); do
for delay in $DELAYS; do
  echo "== repetition $rep, delay $delay ms, $HOPS hops"
  stop_all

  # --- the nodes join one after the other; HOPS_OK = how many of them synced ---
  for k in $(seq "$HOPS"); do
    vm=${VMS[$((k - 1))]}; port=${PORTS[$((k - 1))]}
    if [ "$k" = 1 ]; then
      peer_ip=$POOL_IP; peer_port=3001
    else
      peer_vm=${VMS[$((k - 2))]}; peer_ip=$(ip_of "$peer_vm"); peer_port=${PORTS[$((k - 2))]}
    fi
    res=$(on "$vm" "NAME=hop$k HOST_PORT=$port LISTEN=1 DELAY=$delay LOSS=0 TIMEOUT=1800 \
                    ./experiments/measure/sync-time.sh $peer_ip $peer_port" || true)
    read -r sec blocks _ dbkb rx <<< "${res:-NA NA NA NA NA}"
    echo "$rep,$delay,$k,$vm,$sec,$blocks,$dbkb,$rx" >> "$OUT/join.csv"
    echo "  hop $k ($vm): ${res:-failed}"
    [ -n "$res" ] || { echo "  hop $k did not sync: the chain stops here"; HOPS_OK=$((k - 1)); break; }
    HOPS_OK=$k
  done

  [ -n "$JOIN_ONLY" ] && continue
  [ "$HOPS_OK" -ge 1 ] || { echo "  no node synced at $delay ms"; continue; }
  AFTER=$(date -u +%Y-%m-%dT%H:%M:%S)    # this machine's clock: clock-offsets.py is relative to it
  sleep "$IDLE"

  # --- transactions at hop 1 and at the last hop; the first one (i = 0) is dropped ---
  tx_nodes=1; [ "$HOPS_OK" -gt 1 ] && tx_nodes="1 $HOPS_OK"
  for i in $(seq 0 "$TXS"); do
    for k in $tx_nodes; do
      vm=${VMS[$((k - 1))]}
      r=$(NAME=hop$k "$HERE/tx-latency.sh" "$vm" 2>> "$OUT/tx-errors.log" \
            || { sleep 8; NAME=hop$k "$HERE/tx-latency.sh" "$vm" 2>> "$OUT/tx-errors.log"; })
      [ "$i" = 0 ] || echo "$delay,$k,$r" >> "$OUT/tx.csv"
    done
  done

  # --- block propagation from the logs of the pools and of the nodes ---
  LOGS="$OUT/logs/delay$delay"; mkdir -p "$LOGS"
  for p in 1 2 3; do pool_log $p > "$LOGS/pool$p.log"; done
  for k in $(seq "$HOPS_OK"); do
    ssh -o BatchMode=yes "${VMS[$((k - 1))]}" "docker logs hop$k 2>&1" > "$LOGS/hop$k.log" 2>/dev/null
  done
  OFFSETS=$(python3 -I "$HERE/clock-offsets.py" "$POOL" "$VM2" "$VM4" "$VM3")
  offset() { awk -F, -v m="$1" '$1 == m { print $2 }' <<< "$OFFSETS"; }
  args=(pool1="$LOGS/pool1.log@$(offset "$POOL")" pool2="$LOGS/pool2.log@$(offset "$POOL")"
        pool3="$LOGS/pool3.log@$(offset "$POOL")")
  for k in $(seq "$HOPS_OK"); do args+=("hop$k=$LOGS/hop$k.log@$(offset "${VMS[$((k - 1))]}")"); done
  python3 -I "$HERE/propagation.py" --after "$AFTER" "${args[@]}" 2>> "$OUT/blockrate.txt" \
    | grep '^hop' | sed "s/^hop/$delay,/" >> "$OUT/propagation.csv"
  tail -$((HOPS_OK + 1)) "$OUT/propagation.csv" | sed 's/^/  /'
done
done
stop_all
trap - EXIT
echo "done: $OUT"
