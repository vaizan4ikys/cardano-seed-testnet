#!/bin/bash
# Clock skew tolerance: what happens to a node whose clock is wrong? A node accepts a block header only if
# its slot is not more than ~2 s in the future of the node's own clock (tolerableClockSkew; otherwise the
# connection is dropped: InFutureHeaderExceedsClockSkew). Run from your own machine over SSH.
#
#   ./skew.sh                              OFFSETS="-1 -2 -3 -5 -10 5" on seedvm4, 180 s to sync + 120 s watch
#   OFFSETS="-5" NODE=seedvm2 ./skew.sh
#
# For each offset (seconds; negative = the node's clock is behind the chain's): chrony is stopped on $NODE,
# its clock is set wrong, a fresh node joins from the pool, and every 5 s its block number is compared with
# the pool's. Output (results/skew-<date-time>/skew.csv): offset_s, seconds until within 3 blocks of the pool
# (NA = never), share of the 120 s watch spent within 3 blocks, number of header-too-early drops, connection drops.
# The clock of $NODE is put back (chrony) at the end of every offset and on exit.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
POOL=${POOL:-seedvm}; NODE=${NODE:-seedvm4}
OFFSETS=${OFFSETS:--1 -2 -3 -5 -10 5}
REPS=${REPS:-1}
SYNC_WAIT=${SYNC_WAIT:-180}; WATCH=${WATCH:-120}
REPO=cardano-seed-testnet
OUT=${OUT:-$HERE/results/skew-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
on() { local vm=$1; shift; ssh -A -o BatchMode=yes "$vm" "cd $REPO && $*" 2> >(grep -v '^\*\*' >&2); }
POOL_IP=$(ssh -o BatchMode=yes "$POOL" hostname -I 2>/dev/null | cut -d' ' -f1)
# gap in seconds between the clock of $NODE and of $POOL, both read at the same moment
clock_gap() {
  ssh -o BatchMode=yes "$NODE" 'date +%s.%N' > "$OUT/.n" 2>/dev/null & ssh -o BatchMode=yes "$POOL" 'date +%s.%N' > "$OUT/.p" 2>/dev/null & wait
  awk -v a="$(cat "$OUT/.n")" -v b="$(cat "$OUT/.p")" 'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.2f", d }'
}
# stop the test node, start chrony again and step the clock until it agrees with $POOL (to 0.5 s); the first
# step can come too early (chrony has no sample yet), so repeat
fix_clock() {
  on "$NODE" "./experiments/join-node/join.sh stop >/dev/null 2>&1; sudo systemctl start chrony" >/dev/null 2>&1 || true
  for _ in $(seq 12); do
    sleep 8
    on "$NODE" "sudo chronyc makestep >/dev/null 2>&1; true" >/dev/null 2>&1 || true
    sleep 3
    [ "$(awk -v g="$(clock_gap)" 'BEGIN { print (g < 0.5) }')" = 1 ] && return 0
  done
  echo "WARNING: the clock of $NODE is still $(clock_gap) s off" >&2
}
trap fix_clock EXIT
pool_block() { on "$POOL" 'source scripts/lib.sh && tip_of 1' | grep -o '"block": *[0-9]*' | grep -o '[0-9]*$'; }
node_block() { on "$NODE" 'docker exec cardano-joiner cardano-cli query tip --socket-path /node.socket --testnet-magic 42 2>/dev/null' | grep -o '"block": *[0-9]*' | grep -o '[0-9]*$' || true; }

echo "rep,offset_s,seconds_to_sync,share_in_sync_during_watch,header_too_early,connection_drops" > "$OUT/skew.csv"
echo "date: $(date -u +%FT%TZ)    node: $NODE    offsets: $OFFSETS" | tee "$OUT/setup.txt"
on "$NODE" "./experiments/join-node/fetch-chain-files.sh seed@$POOL_IP" >/dev/null

for rep in $(seq "$REPS"); do for off in $OFFSETS; do
  echo "== repetition $rep, clock offset $off s on $NODE"
  fix_clock
  on "$NODE" "sudo systemctl stop chrony; sudo date -s @\$((\$(date +%s) + ($off)))" >/dev/null
  on "$NODE" "./experiments/join-node/join.sh remote $POOL_IP 3001" >/dev/null
  t0=$(date +%s); synced=NA
  while [ $(( $(date +%s) - t0 )) -lt "$SYNC_WAIT" ]; do
    p=$(pool_block); n=$(node_block)
    if [ -n "${n:-}" ] && [ -n "${p:-}" ] && [ $((p - n)) -le 3 ]; then synced=$(( $(date +%s) - t0 )); break; fi
    sleep 5
  done
  ok=0; total=0; t1=$(date +%s)
  while [ $(( $(date +%s) - t1 )) -lt "$WATCH" ]; do
    p=$(pool_block); n=$(node_block); total=$((total + 1))
    [ -n "${n:-}" ] && [ -n "${p:-}" ] && [ $((p - n)) -le 3 ] && ok=$((ok + 1))
    sleep 5
  done
  logs=$(on "$NODE" 'docker logs cardano-joiner 2>&1')
  early=$(grep -c "InFutureHeaderExceedsClockSkew" <<< "$logs" || true)
  drops=$(grep -c "Net.Mux.Remote.ExceptionExit" <<< "$logs" || true)
  echo "$logs" > "$OUT/node-offset$off-rep$rep.log"
  echo "$rep,$off,$synced,$(awk -v o=$ok -v t=$total 'BEGIN { printf "%.2f", t ? o / t : 0 }'),$early,$drops" | tee -a "$OUT/skew.csv"
done; done
fix_clock; trap - EXIT
echo "clock of $NODE restored: $(on "$NODE" 'chronyc tracking | grep "System time"')"
echo "done: $OUT"
