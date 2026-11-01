#!/bin/bash
# Saturation test: how many sensor readings per second can the chain take, and what does a reading
# cost in waiting time when it gets close to that limit? Run from your own machine over SSH.
#
#   ./saturate.sh                                   the whole series
#   STEPS="100:1 100:3" DURATION=60 ./saturate.sh   a short test: <readings per tx>:<tx per second> ...
#   STOP_LOAD=1 ./saturate.sh                       stop ../load first (it must not run: it fills the blocks)
#
# One step = DURATION seconds of submitting transactions with B readings each at a fixed rate from pool
# 1's container (in-container/sat-step.sh), then waiting until they are all in blocks. Results go to
# results/saturation-<date-time>/: steps.csv (one row per step), txs-B<b>-r<rate>.csv (one row per
# transaction), rejects-*.log. summarize.py makes the table.
#
# Needs network 1 running on $POOL (a joiner is not needed). It writes to the chain: about 1 MB per step.
# Rates that need more than ~20 transactions per second cannot be reached (cardano-cli starts a process
# for every transaction): for 1 and 10 readings per transaction that is below what the node could take,
# so those rows show the limit of the generator, not of the chain. See README.md.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
POOL=${POOL:-seedvm}
REPO=cardano-seed-testnet
STEPS=${STEPS:-"1:2 1:5 1:10 1:20 10:2 10:5 10:10 10:15 100:1 100:2 100:3 100:4 100:6 300:0.5 300:1 300:1.5 300:2"}
DURATION=${DURATION:-120}
REST=${REST:-20}                       # seconds between steps
OUT=${OUT:-$HERE/results/saturation-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"

on() { ssh -A -o BatchMode=yes "$POOL" "cd $REPO && $*" 2> >(grep -v -e '^\*\*' >&2); }
in_pool() { on "source scripts/lib.sh && P=\$(require_pool 1) && $*"; }
tip() { on 'source scripts/lib.sh && tip_of 1' | grep -o '"block": *[0-9]*' | grep -o '[0-9]*$'; }
mempool() { in_pool 'docker exec $P cardano-cli conway query tx-mempool info --socket-path /node.socket --testnet-magic $MAGIC' | jq -r .numberOfTxs; }

# the load must be off
LOAD_STATE=$(on './experiments/load/load.sh status' | head -1 || true)
if [ "$LOAD_STATE" = running ]; then
  [ "${STOP_LOAD:-}" = 1 ] && on './experiments/load/load.sh stop' || { echo "the load is running: stop it (./experiments/load/load.sh stop) or use STOP_LOAD=1"; exit 1; }
fi
rsync -a "$HERE/in-container/" "$POOL:$REPO/experiments/saturation/in-container/" 2> >(grep -v -e '^\*\*' >&2)
in_pool 'docker exec $P mkdir -p /tmp/sat-scripts && docker cp experiments/saturation/in-container/. $P:/tmp/sat-scripts/'

# wait until the mempool is empty (the previous step's leftovers must not disturb the next)
drain() {
  local n
  for _ in $(seq 120); do
    n=$(mempool); [ "$n" = 0 ] && return 0; sleep 5
  done
  echo "mempool still has $n transactions after 10 minutes" >&2; return 1
}

{
  echo "date: $(date -u +%FT%TZ)    commit: $(git -C "$HERE" rev-parse --short HEAD 2>/dev/null)    steps: $STEPS    duration: $DURATION s"
  echo "chain at start: $(on 'source scripts/lib.sh && tip_of 1')"
  echo "pool machine: $(on 'echo "$(nproc) CPU, $(free -m | awk "/^Mem/ {print \$2}") MiB RAM"')"
} | tee "$OUT/setup.txt"

drain
SKIP=""                                 # batch sizes whose higher rates are skipped (a step lost transactions)
for step in $STEPS; do
  b=${step%%:*}; rate=${step#*:}
  case " $SKIP " in *" $b "*) echo "skip $step (lower rate of batch $b already lost transactions)"; continue ;; esac
  lanes=4; [ "$(awk -v r="$rate" 'BEGIN { print (r > 8) }')" = 1 ] && lanes=8

  avail=$(on 'free -m | awk "/^Mem/ {print \$7}"')
  [ "$avail" -ge 400 ] || { echo "only $avail MiB free on $POOL: stopping"; exit 1; }
  before=$(tip)
  echo "== $(date +%T) batch $b readings/tx, $rate tx/s, $lanes lanes, $DURATION s"
  in_pool "docker exec -e MAGIC=\$MAGIC -e B=$b -e RATE=$rate -e DURATION=$DURATION -e LANES=$lanes \$P bash /tmp/sat-scripts/sat-step.sh" > "$OUT/.step" || { echo "step failed"; cat "$OUT/.step"; exit 1; }
  [ -f "$OUT/steps.csv" ] || head -1 "$OUT/.step" > "$OUT/steps.csv"
  tail -1 "$OUT/.step" >> "$OUT/steps.csv"
  tail -1 "$OUT/.step"
  in_pool 'docker exec $P cat /tmp/sat/step/txs.csv' > "$OUT/txs-B$b-r$rate.csv"
  in_pool 'docker exec $P cat /tmp/sat/step/rejects.log' > "$OUT/rejects-B$b-r$rate.log" || true
  [ -s "$OUT/rejects-B$b-r$rate.log" ] || rm -f "$OUT/rejects-B$b-r$rate.log"

  after=$(tip)
  [ "$after" -gt "$before" ] || { echo "the chain did not advance during the step ($before -> $after): stopping"; exit 1; }
  lost=$(tail -1 "$OUT/.step" | cut -d, -f13)
  [ "$lost" = 0 ] || SKIP="$SKIP $b"
  drain || exit 1
  sleep "$REST"
done
rm -f "$OUT/.step"
echo "done: $OUT"
