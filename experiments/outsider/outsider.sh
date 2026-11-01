#!/bin/bash
# Outsider experiment: a rogue block producer with its OWN genesis dials a pool of the real network.
# Run from your own machine over SSH; the real network must run on $POOL with EXPOSE=1 and a spare
# machine $ROGUE must have the repo (see rogue.sh).
#
#   ./outsider.sh                              both variants, 10 minutes of rogue each
#   VARIANTS="42" MINUTES=3 ./outsider.sh      a short test
#
# Variants are the network magic of the rogue network:
#   42  the SAME magic as the real network: the handshake cannot tell them apart, the chains differ
#       (other genesis, keys, pool). Who notices, how fast, and does the real chain suffer?
#   43  a DIFFERENT magic: the handshake refuses at once (the reference for how fast a rejection can be).
# "Real genesis, other magic" cannot be built: the magic is a field of the genesis, and Byron's genesis
# certificates are signed over it (changing it: the node refuses to start, InvalidCertificate; changing only
# the Shelley file leaves the handshake magic at 42 and makes a different genesis, as in the first case).
# Real genesis and real magic is an ordinary joiner (see ../join-node).
# For each: BASE minutes without the rogue, MINUTES with it, AFTER minutes without it again.
# Every 10 s the block height of the real chain (pool 1) and of the rogue chain is recorded, and the
# counters of the pool logs are taken at the phase boundaries.
#
# Output: results/outsider-<date-time>/timeline.csv, counters.csv, rogue-<magic>.log (the rogue's own
# connection log), pool1-<magic>.log (the lines of pool 1 about connections during the rogue phase).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
POOL=${POOL:-seedvm}; ROGUE=${ROGUE:-seedvm3}
VARIANTS=${VARIANTS:-"42 43"}
BASE=${BASE:-5}; MINUTES=${MINUTES:-10}; AFTER=${AFTER:-5}
REPO=cardano-seed-testnet
OUT=${OUT:-$HERE/results/outsider-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"

on() { local vm=$1; shift; ssh -A -o BatchMode=yes "$vm" "cd $REPO && $*" 2> >(grep -v -e '^\*\*' >&2); }
POOL_IP=$(ssh -o BatchMode=yes "$POOL" hostname -I 2>/dev/null | cut -d' ' -f1)
trap 'on "$ROGUE" "./experiments/outsider/rogue.sh stop" >/dev/null 2>&1 || true' EXIT

real_block()  { on "$POOL" 'source scripts/lib.sh && tip_of 1' | grep -o '"block": *[0-9]*' | grep -o '[0-9]*$'; }
rogue_block() { on "$ROGUE" './experiments/outsider/rogue.sh tip' 2>/dev/null | grep -o '"block": *[0-9]*' | grep -o '[0-9]*$' || echo NA; }
vm_now()      { on "$POOL" 'date -u +%Y-%m-%dT%H:%M:%S'; }
count()       { on "$POOL" 'source scripts/lib.sh && docker exec $(pool_container 1) grep -ac "'"$1"'" /var/log/cardano-node.log' || echo 0; }

echo "magic,phase,time_utc,real_block,rogue_block" > "$OUT/timeline.csv"
echo "magic,phase,minutes,real_blocks,blocks_per_min,connection_exceptions_pool1,fork_switches_pool1,rollbacks_pool1" > "$OUT/counters.csv"
{
  echo "date: $(date -u +%FT%TZ)    variants: $VARIANTS    base/rogue/after minutes: $BASE/$MINUTES/$AFTER"
  echo "chain at start: $(on "$POOL" 'source scripts/lib.sh && tip_of 1')"
  echo "load: $(on "$POOL" './experiments/load/load.sh status' | head -1)"
} | tee "$OUT/setup.txt"

# a phase: sample for $2 minutes every 10 s, then one counters row
phase() {   # magic name minutes
  local magic=$1 name=$2 minutes=$3 b0 b1 x0 x1 f0 f1 r0 r1 t0 t1 end
  b0=$(real_block); x0=$(count "Net.Mux.Remote.ExceptionExit"); f0=$(count "AddBlockEvent.SwitchedToAFork"); r0=$(count "ChainSync.Client.RolledBack"); t0=$(date +%s)
  end=$((t0 + minutes * 60))
  while [ "$(date +%s)" -lt "$end" ]; do
    echo "$magic,$name,$(vm_now),$(real_block),$([ "$name" = rogue ] && rogue_block || echo NA)" >> "$OUT/timeline.csv"
    sleep 6
  done
  b1=$(real_block); x1=$(count "Net.Mux.Remote.ExceptionExit"); f1=$(count "AddBlockEvent.SwitchedToAFork"); r1=$(count "ChainSync.Client.RolledBack"); t1=$(date +%s)
  awk -v m="$magic" -v p="$name" -v s=$((t1 - t0)) -v b=$((b1 - b0)) -v x=$((x1 - x0)) -v f=$((f1 - f0)) -v r=$((r1 - r0)) \
    'BEGIN { printf "%s,%s,%.1f,%d,%.2f,%d,%d,%d\n", m, p, s / 60, b, b * 60 / s, x, f, r }' | tee -a "$OUT/counters.csv"
}

for magic in $VARIANTS; do
  echo "== rogue network with magic $magic"
  on "$ROGUE" "./experiments/outsider/rogue.sh stop" >/dev/null 2>&1 || true
  phase "$magic" before "$BASE"

  T_START=$(vm_now)
  on "$ROGUE" "./experiments/outsider/rogue.sh gen $magic >/dev/null && ./experiments/outsider/rogue.sh start $POOL_IP 3001" >/dev/null
  echo "rogue started at $T_START (VM clock)"
  phase "$magic" rogue "$MINUTES"
  on "$ROGUE" "./experiments/outsider/rogue.sh log" > "$OUT/rogue-$magic.log" 2>&1 || true
  on "$ROGUE" "./experiments/outsider/rogue.sh stop" >/dev/null
  T_STOP=$(vm_now)

  # what pool 1 logged about connections while the rogue was there
  on "$POOL" 'source scripts/lib.sh && docker exec $(pool_container 1) grep -a -e "Net.Mux.Remote" -e "ConnectionManager.Remote" -e "InboundGovernor.Remote" -e "Handshake" /var/log/cardano-node.log' \
    | grep -v "TraceEmitDeltaQ" | awk -v a="$T_START" '{ t = substr($1, 2, 10) "T" substr($2, 1, 8); if (t >= a) print }' | cut -c1-400 > "$OUT/pool1-$magic.log" || true
  phase "$magic" after "$AFTER"
done
echo "done: $OUT"
