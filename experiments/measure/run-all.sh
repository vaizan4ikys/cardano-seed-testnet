#!/bin/bash
# The whole measurement series, driven from your own machine over SSH. Results go to
# results/<date-time>/ as CSV files (see README.md for what each one holds).
#
#   ./run-all.sh                                         the full matrix
#   DELAYS="0 100" LOSSES="0" REPS=1 TXS=2 IDLE=20 ./run-all.sh    a short test run
#
# Needs: network 1 running on $POOL with EXPOSE=1 and the chain at the height you want to test
# at; the four machines reachable by ssh; this repo cloned on each of them.
#
#   POOL   (seedvm)    hosts the network, builds and signs the transactions
#   HOP1   (seedvm2)   joiner that dials a pool; also serves HOP2
#   HOP1B  (seedvm3)   second joiner that dials a pool (only for the parallel test)
#   HOP2   (seedvm4)   joiner that dials HOP1, two hops from the pools
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
POOL=${POOL:-seedvm};  HOP1=${HOP1:-seedvm2};  HOP1B=${HOP1B:-seedvm3};  HOP2=${HOP2:-seedvm4}
DELAYS=${DELAYS:-"0 50 100 200 500"}      # ms added to each joiner's link
LOSSES=${LOSSES:-"0 1"}                   # % packet loss on each joiner's link
REPS=${REPS:-3}                           # syncs from an empty database per setting
TXS=${TXS:-10}                            # transactions per node and setting (one more, not recorded, comes first)
IDLE=${IDLE:-120}                         # seconds of quiet chain before the transactions
REPO=cardano-seed-testnet
OUT=${OUT:-$HERE/results/$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT/logs"

# run a command in the repo on a machine ("-A": the machine may need your key to reach the pool)
on() { local vm=$1; shift; ssh -A -o BatchMode=yes "$vm" "cd $REPO && $*" 2> >(grep -v '^\*\*' >&2); }
ip_of() { ssh -o BatchMode=yes "$1" hostname -I 2>/dev/null | cut -d' ' -f1; }

POOL_IP=$(ip_of "$POOL")
HOP1_IP=$(ip_of "$HOP1")

# one sync from an empty database on machine $1 through peer $2 (extra env in $3): "<seconds> <blocks>"
sync_node() { on "$1" "DELAY=$delay LOSS=$loss ${3:-} ./experiments/measure/sync-time.sh $2" || true; }
stop_joiners() { for vm in "$HOP2" "$HOP1" "$HOP1B"; do on "$vm" "./experiments/join-node/join.sh stop" >/dev/null; done; }

# sync.csv row: mode,rep,node,hops,<seconds blocks ready-seconds db-kB>
add_sync() {
  # a sync that failed (not caught up after 900 s) prints nothing: the row says NA
  awk -v d="$delay" -v l="$loss" -v m="$1" -v r="$2" -v n="$3" -v h="$4" -v res="$5" \
    'BEGIN { split(res, x, " ")
             if (x[1] == "") printf "%s,%s,%s,%s,%s,%s,NA,NA,NA,NA,NA\n", d, l, m, r, n, h
             else printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%.1f,%s\n", d, l, m, r, n, h, x[1], x[3], x[2], x[1] - x[3], x[4] }' >> "$OUT/sync.csv"
}

echo "delay_ms,loss_pct,mode,rep,node,hops,seconds,ready_seconds,blocks,sync_seconds,db_kb" > "$OUT/sync.csv"
echo "delay_ms,loss_pct,node,hops,seconds,mempool_seconds" > "$OUT/tx.csv"
echo "delay_ms,loss_pct,node,blocks,median_ms,p95_ms,max_ms" > "$OUT/propagation.csv"
: > "$OUT/blockrate.txt"
echo "delay_ms,loss_pct,machine,offset_ms,round_trip_ms" > "$OUT/offsets.csv"

# --- the setup of this run, for later reading
{
  echo "date: $(date -u +%FT%TZ)    commit: $(git -C "$HERE" rev-parse --short HEAD)"
  for vm in "$POOL" "$HOP1" "$HOP1B" "$HOP2"; do
    echo "$vm: $(on "$vm" 'echo "$(nproc) CPU, $(free -m | awk "/^Mem/ {print \$2}") MiB RAM, $(chronyc tracking 2>/dev/null | grep 'System time' | xargs)"')"
  done
  echo "chain at start: $(on "$POOL" 'source scripts/lib.sh && tip_of 1')"
} | tee "$OUT/setup.txt"

for vm in "$HOP1" "$HOP1B" "$HOP2"; do on "$vm" "./experiments/join-node/fetch-chain-files.sh seed@$POOL_IP" >/dev/null; done

# --- one discarded run: the first start after a boot reads everything from disk
delay=0; loss=0
echo "warm-up (not recorded)"
stop_joiners
sync_node "$HOP1" "$POOL_IP" LISTEN=1 >/dev/null
sync_node "$HOP2" "$HOP1_IP" >/dev/null

# --- two joiners syncing from the pools at the same time (no extra delay)
echo "parallel sync of $HOP1, $HOP1B and $HOP2, all from the pools"
for rep in $(seq "$REPS"); do
  stop_joiners
  sync_node "$HOP1"  "$POOL_IP" > "$OUT/.p1" &
  sync_node "$HOP1B" "$POOL_IP" > "$OUT/.p2" &
  sync_node "$HOP2" "$POOL_IP" > "$OUT/.p3" &
  wait
  add_sync parallel "$rep" "$HOP1"  1 "$(cat "$OUT/.p1")"
  add_sync parallel "$rep" "$HOP1B" 1 "$(cat "$OUT/.p2")"
  add_sync parallel "$rep" "$HOP2" 1 "$(cat "$OUT/.p3")"
done
rm -f "$OUT/.p1" "$OUT/.p2" "$OUT/.p3"

# --- every delay/loss setting
for delay in $DELAYS; do
  for loss in $LOSSES; do
    echo "== delay $delay ms, loss $loss %"
    for rep in $(seq "$REPS"); do
      stop_joiners
      add_sync single "$rep" "$HOP1" 1 "$(sync_node "$HOP1" "$POOL_IP" LISTEN=1)"
      add_sync single "$rep" "$HOP2" 2 "$(sync_node "$HOP2" "$HOP1_IP")"
    done
    # the joiners of the last repetition stay up for the rest of this setting

    AFTER=$(date -u +%Y-%m-%dT%H:%M:%S)    # blocks forged after this are propagation samples; this machine's clock, because clock-offsets.py is relative to it
    sleep "$IDLE"

    # the first transaction after a start is not representative: send one and drop it
    for i in $(seq 0 "$TXS"); do
      for node_hops in "$HOP1:1" "$HOP2:2"; do
        vm=${node_hops%:*}
        seconds=$("$HERE/tx-latency.sh" "$vm" 2>> "$OUT/tx-errors.log" || { echo "--- $vm failed, retrying" >> "$OUT/tx-errors.log"; sleep 8; "$HERE/tx-latency.sh" "$vm"; })
        [ "$i" = 0 ] || echo "$delay,$loss,$vm,${node_hops#*:},$seconds" >> "$OUT/tx.csv"
      done
    done

    # propagation: the logs of the three pools and the two joiners
    LOGS="$OUT/logs/delay${delay}_loss${loss}"; mkdir -p "$LOGS"
    for p in 1 2 3; do on "$POOL" "source scripts/lib.sh && docker exec \$(pool_container $p) cat /var/log/cardano-node.log" > "$LOGS/pool$p.log"; done
    for vm in "$HOP1" "$HOP2"; do ssh -o BatchMode=yes "$vm" "docker logs cardano-joiner 2>&1" > "$LOGS/$vm.log" 2>/dev/null; done
    # put the logs of all machines on one timeline
    OFFSETS=$(python3 -I "$HERE/clock-offsets.py" "$POOL" "$HOP1" "$HOP2")
    sed "s/^/$delay,$loss,/" <<< "$OFFSETS" >> "$OUT/offsets.csv"
    offset() { awk -F, -v m="$1" '$1 == m { print $2 }' <<< "$OFFSETS"; }
    python3 -I "$HERE/propagation.py" --after "$AFTER" \
        pool1="$LOGS/pool1.log@$(offset "$POOL")" pool2="$LOGS/pool2.log@$(offset "$POOL")" pool3="$LOGS/pool3.log@$(offset "$POOL")" \
        "$HOP1=$LOGS/$HOP1.log@$(offset "$HOP1")" "$HOP2=$LOGS/$HOP2.log@$(offset "$HOP2")" \
        2>> "$OUT/blockrate.txt" | sed "s/^/$delay,$loss,/" >> "$OUT/propagation.csv"
    echo "delay $delay ms, loss $loss %: $(tail -1 "$OUT/blockrate.txt")" >> "$OUT/blockrate.txt"
  done
done

stop_joiners
echo "done: $OUT"
