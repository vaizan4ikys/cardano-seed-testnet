#!/bin/bash
# Repeat a small measurement series at regular intervals while the chain grows (for example under
# ../load/load.sh), to see how join time, transaction latency and propagation change with the size
# of the chain. Run it on your own machine; leave the machine awake (caffeinate -dims).
#
#   ./checkpoints.sh                         a checkpoint every 30 minutes, 24 of them
#   INTERVAL=1800 COUNT=24 ./checkpoints.sh
#   touch results/growth-<date-time>/stop    ends it after the current checkpoint
#   OUT=results/growth-<date-time> ./checkpoints.sh    carries on with an existing folder (numbering continues)
#
# One checkpoint = ./run-all.sh with delay 0 and 100 ms, no loss (2 joins, 6 transactions per
# node, a quiet minute) plus the state of the chain. Results go to results/growth-<date-time>/:
# chain.csv (one row per checkpoint; immutable_kb is the chain itself, db_kb adds the volatile blocks, which are cleaned up in steps) and cp-NN/ (the files of run-all.sh). growth.py joins them.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
POOL=${POOL:-seedvm}
INTERVAL=${INTERVAL:-1800}
COUNT=${COUNT:-24}
OUT=${OUT:-$HERE/results/growth-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
[ -f "$OUT/chain.csv" ] || echo "checkpoint,time_utc,block,db_kb,immutable_kb,load_txs,mempool_txs" > "$OUT/chain.csv"
DONE=$(ls -d "$OUT"/cp-* 2>/dev/null | grep -c -v "\.log$" || true)   # checkpoints of an earlier start
rm -f "$OUT/stop"

for n in $(seq $((DONE + 1)) $((DONE + COUNT))); do
  CP=$(printf 'cp-%02d' "$n")
  STARTED=$(date +%s)

  # the chain: tip block, size of pool 1's database (kB; all of it, and the immutable part), transactions the load has sent, mempool
  STATE=$(ssh -o BatchMode=yes "$POOL" 'bash -s' 2> >(grep -v '^\*\*' >&2) <<'REMOTE' | tr ' ' ','
cd cardano-seed-testnet && source scripts/lib.sh
c=$(pool_container 1)
echo "$(docker exec $c cardano-cli conway query tip --socket-path $SOCKET --testnet-magic $MAGIC | jq .block)" \
     "$(docker exec $c du -sk /cardano-db | cut -f1)" \
     "$(docker exec $c du -sk /cardano-db/immutable | cut -f1)" \
     "$(docker exec $c cat /tmp/load.count 2>/dev/null || echo 0)" \
     "$(docker exec $c cardano-cli conway query tx-mempool info --socket-path $SOCKET --testnet-magic $MAGIC | jq .numberOfTxs)"
REMOTE
)
  echo "$CP,$(date -u +%FT%TZ),$STATE" >> "$OUT/chain.csv"
  echo "$(date +%T) $CP: block/db_kB/load/mempool = $STATE"

  OUT="$OUT/$CP" DELAYS="0 100" LOSSES="0" REPS=2 TXS=6 IDLE=30 "$HERE/run-all.sh" > "$OUT/$CP.log" 2>&1 \
    || echo "$(date +%T) $CP: run-all.sh failed, see $CP.log"

  [ ! -f "$OUT/stop" ] || { echo "stop file found"; break; }
  WAIT=$(( STARTED + INTERVAL - $(date +%s) ))
  [ "$WAIT" -le 0 ] || sleep "$WAIT"
done
echo "done: $OUT"
