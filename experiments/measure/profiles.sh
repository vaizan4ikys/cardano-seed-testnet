#!/bin/bash
# Realistic link profiles instead of plain delay: bandwidth caps (down/up), delay and loss together.
# Run from your own machine over SSH, like run-all.sh.
#
#   ./profiles.sh                                   the five default profiles, about 2 hours on a 450 MB chain
#   PROFILES="fibre:100:100:5:0:1:1" REPS=1 ./profiles.sh
#
# A profile is  <name>:<down Mbit/s>:<up Mbit/s>:<delay ms>:<loss %>:<repetitions>:<hop 2 too (1/0)>
# The joiner of hop 1 gets the profile on its link (delay and loss act on what it sends, see netem.sh).
# Hop 2 downloads through hop 1, so the upload cap of hop 1 limits it: with a slow upload it is left out (0).
# Per profile: join time from an empty database, latency of $TXS transactions (quiet chain: the load
# must be off), block propagation. Output in results/profiles-<date-time>/: sync.csv, tx.csv, propagation.csv.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
POOL=${POOL:-seedvm}; HOP1=${HOP1:-seedvm2}; HOP2=${HOP2:-seedvm4}
PROFILES=${PROFILES:-"fibre:100:100:5:0:2:1 cable:50:10:10:0.1:2:1 mobile4g:20:5:40:0.5:2:0 rural-dsl:5:2:25:0.5:1:0 satellite:25:3:300:0.5:1:0"}
TXS=${TXS:-8}                             # transactions per node and profile (one more, not recorded, comes first)
IDLE=${IDLE:-180}                         # seconds of quiet chain before the transactions (propagation samples)
export TIMEOUT=${TIMEOUT:-3000}           # a join slower than this counts as failed (NA)
REPO=cardano-seed-testnet
OUT=${OUT:-$HERE/results/profiles-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT/logs"

on() { local vm=$1; shift; ssh -A -o BatchMode=yes "$vm" "cd $REPO && $*" 2> >(grep -v '^\*\*' >&2); }
ip_of() { ssh -o BatchMode=yes "$1" hostname -I 2>/dev/null | cut -d' ' -f1; }
stop_joiners() { for vm in "$HOP2" "$HOP1"; do on "$vm" "./experiments/join-node/join.sh stop" >/dev/null 2>&1 || true; done; }
trap stop_joiners EXIT

POOL_IP=$(ip_of "$POOL"); HOP1_IP=$(ip_of "$HOP1")
echo "profile,down_mbit,up_mbit,delay_ms,loss_pct,rep,node,hops,seconds,ready_seconds,blocks,sync_seconds,db_kb" > "$OUT/sync.csv"
echo "profile,node,hops,seconds,mempool_seconds" > "$OUT/tx.csv"
echo "profile,node,blocks,median_ms,p95_ms,max_ms" > "$OUT/propagation.csv"
: > "$OUT/blockrate.txt"
{
  echo "date: $(date -u +%FT%TZ)    profiles: $PROFILES    timeout: $TIMEOUT s"
  echo "chain at start: $(on "$POOL" 'source scripts/lib.sh && tip_of 1')"
  echo "load: $(on "$POOL" './experiments/load/load.sh status' | head -1)"
} | tee "$OUT/setup.txt"

for vm in "$HOP1" "$HOP2"; do on "$vm" "./experiments/join-node/fetch-chain-files.sh seed@$POOL_IP" >/dev/null; done

# sync.csv row from "<seconds> <blocks> <ready> <db kB>" (empty: failed)
add_sync() {   # name down up delay loss rep node hops result
  awk -v p="$1" -v d="$2" -v u="$3" -v dl="$4" -v l="$5" -v r="$6" -v n="$7" -v h="$8" -v res="$9" \
    'BEGIN { split(res, x, " ")
             if (x[1] == "") printf "%s,%s,%s,%s,%s,%s,%s,%s,NA,NA,NA,NA,NA\n", p, d, u, dl, l, r, n, h
             else printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%.1f,%s\n", p, d, u, dl, l, r, n, h, x[1], x[3], x[2], x[1] - x[3], x[4] }' >> "$OUT/sync.csv"
}

# one discarded join: the first start after a boot reads everything from disk
stop_joiners
on "$HOP1" "LISTEN=1 ./experiments/measure/sync-time.sh $POOL_IP" > /dev/null || true

for profile in $PROFILES; do
  IFS=: read -r name down up delay loss reps hop2 <<< "$profile"
  echo "== $name: down $down Mbit/s, up $up, delay $delay ms, loss $loss %"
  for rep in $(seq "$reps"); do
    stop_joiners
    r1=$(on "$HOP1" "DOWN=$down UP=$up DELAY=$delay LOSS=$loss LISTEN=1 ./experiments/measure/sync-time.sh $POOL_IP" || true)
    add_sync "$name" "$down" "$up" "$delay" "$loss" "$rep" "$HOP1" 1 "$r1"; echo "  rep $rep hop 1: ${r1:-failed}"
    if [ "$hop2" = 1 ]; then
      r2=$(on "$HOP2" "DOWN=$down UP=$up DELAY=$delay LOSS=$loss ./experiments/measure/sync-time.sh $HOP1_IP" || true)
      add_sync "$name" "$down" "$up" "$delay" "$loss" "$rep" "$HOP2" 2 "$r2"; echo "  rep $rep hop 2: ${r2:-failed}"
    fi
  done
  [ -n "${r1:-}" ] || { echo "  hop 1 did not sync: no further measurements for $name"; continue; }

  AFTER=$(date -u +%Y-%m-%dT%H:%M:%S)      # this machine's clock: clock-offsets.py is relative to it
  sleep "$IDLE"
  nodes="$HOP1:1"; [ "$hop2" = 1 ] && [ -n "${r2:-}" ] && nodes="$nodes $HOP2:2"
  for i in $(seq 0 "$TXS"); do
    for node_hops in $nodes; do
      vm=${node_hops%:*}
      s=$("$HERE/tx-latency.sh" "$vm" 2>> "$OUT/tx-errors.log" || { sleep 8; "$HERE/tx-latency.sh" "$vm" 2>> "$OUT/tx-errors.log"; })
      [ "$i" = 0 ] || echo "$name,$vm,${node_hops#*:},$s" >> "$OUT/tx.csv"
    done
  done

  LOGS="$OUT/logs/$name"; mkdir -p "$LOGS"
  for p in 1 2 3; do on "$POOL" "source scripts/lib.sh && docker exec \$(pool_container $p) cat /var/log/cardano-node.log" > "$LOGS/pool$p.log"; done
  args=(); machines=("$POOL" "$HOP1")
  for node_hops in $nodes; do vm=${node_hops%:*}; ssh -o BatchMode=yes "$vm" "docker logs cardano-joiner 2>&1" > "$LOGS/$vm.log" 2>/dev/null; done
  [ "$nodes" != "$HOP1:1" ] && machines+=("$HOP2")
  OFFSETS=$(python3 -I "$HERE/clock-offsets.py" "${machines[@]}")
  offset() { awk -F, -v m="$1" '$1 == m { print $2 }' <<< "$OFFSETS"; }
  args=(pool1="$LOGS/pool1.log@$(offset "$POOL")" pool2="$LOGS/pool2.log@$(offset "$POOL")" pool3="$LOGS/pool3.log@$(offset "$POOL")" "$HOP1=$LOGS/$HOP1.log@$(offset "$HOP1")")
  [ "$nodes" != "$HOP1:1" ] && args+=("$HOP2=$LOGS/$HOP2.log@$(offset "$HOP2")")
  python3 -I "$HERE/propagation.py" --after "$AFTER" "${args[@]}" 2>> "$OUT/blockrate.txt" | sed "s/^/$name,/" >> "$OUT/propagation.csv"
  echo "$name: $(tail -1 "$OUT/blockrate.txt")" >> "$OUT/blockrate.txt"
done
stop_joiners
echo "done: $OUT"
