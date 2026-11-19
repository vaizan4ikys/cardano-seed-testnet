#!/bin/bash
# Runs INSIDE pool 1's container. One step of the Phase 3 load test: variant V (P, S or R), RATE transactions per second
# in total, DURATION seconds, LANES chains. Like experiments/saturation/in-container/sat-step.sh, plus: the tip block
# number is recorded with every sample, so the analysis also counts in blocks.
# The transactions are built and signed BEFORE the step.
#   ./p3-step.sh <magic> <variant> <rate> <duration> [outdir]       DRY_RUN=1: build 3 per lane, print sizes, submit nothing
# Environment: LANES (parallel chains of transactions, default 8), DRAIN (seconds to wait for the last transactions to
# be confirmed, default 240), GIVEUP (seconds after which a refused submit is given up, default 60), DRY_RUN.
set -u
MAGIC=${1:?}; V=${2:?variant P|S|R}; RATE=${3:?tx/s}; DURATION=${4:-60}
export MAGIC
LANES=${LANES:-8}; DRAIN=${DRAIN:-240}; GIVEUP=${GIVEUP:-60}; DRY_RUN=${DRY_RUN:-}
. /tmp/p3-scripts/p3-lib.sh
S=$W/step; rm -rf "$S"; mkdir -p "$S"; cd "$S" || exit 1
use_variant "$V"
[ "$V" != P ] && EXU="($(cat $W/exu.steps),$(cat $W/exu.mem))" || EXU=""
B=100           # readings per transaction (the batch file has 100)

# lanes: the LANES biggest coins of the payer (not the collateral coin), with their receipt counts
cli query utxo --address "$ADDR" --output-json --testnet-magic "$MAGIC" \
  | jq -r --arg coll "${COLL:-none}" --arg pw "$PW" --arg t "$RHEX" --argjson l "$LANES" \
      'to_entries | map(select(.key != $coll)) | sort_by(-.value.value.lovelace)[:$l][]
       | "\(.key) \(.value.value.lovelace) \(.value.value[$pw][$t] // 0)"' > lanes.txt
[ "$(wc -l < lanes.txt)" -ge "$LANES" ] || { echo "fewer than $LANES lane coins at $ADDR" >&2; exit 1; }
read -r IN0 VAL0 TOK0 < <(head -1 lanes.txt)
FEE=$(min_fee "$IN0" "$VAL0" "$TOK0") || { echo "cannot build a draft" >&2; exit 1; }; FEE=$((FEE + 1000))
# N = transactions per lane = ceil(RATE * DURATION / LANES)
N=$(awk -v r="$RATE" -v d="$DURATION" -v l="$LANES" 'BEGIN { n = r * d / l; printf "%d", (n == int(n)) ? n : int(n) + 1 }')
[ "$DRY_RUN" = 1 ] && N=3

# build_lane LANE FIRSTINPUT VALUE RECEIPTS: build and sign the N chained transactions of one lane (before the step)
build_lane() {
  local i=$1 in=$2 val=$3 tok=$4 k id
  mkdir -p lane$i; : > lane$i/ids
  for k in $(seq 0 $((N - 1))); do
    [ "$val" -gt 5000000 ] || { echo "lane $i: funds run out at tx $k" >&2; return 1; }
    mk_tx "$in" "$val" "$tok" "$FEE" "lane$i/t$k" || return 1
    id=$(txid_of lane$i/t$k.signed)
    echo "$id $i $k" >> lane$i/ids
    rm -f lane$i/t$k.raw
    in="$id#0"; val=$((val - FEE)); [ "$V" = P ] || tok=$((tok + 1))
  done
}
BUILD_START=$(now); i=0
while read -r txin val tok; do build_lane "$i" "$txin" "$val" "$tok" & i=$((i + 1)); done < lanes.txt
wait
cat lane*/ids > ids.all
[ "$(wc -l < ids.all)" -eq $((N * LANES)) ] \
  || { echo "building failed: $(wc -l < ids.all) of $((N * LANES)) transactions" >&2; exit 1; }
SIZE=$(size_of lane0/t0.signed)
echo "built $((N * LANES)) transactions ($V) of $SIZE bytes in" \
     "$(awk -v a="$BUILD_START" -v b="$(now)" 'BEGIN { printf "%.0f", b - a }') s (fee $FEE)" >&2
[ "$DRY_RUN" = 1 ] && { echo "variant=$V size_bytes=$SIZE fee=$FEE exu=$EXU"; exit 0; }

: > submits.txt; : > rejects.log; : > samples.txt; : > mempool.txt; : > blocks.txt
T0=$(awk -v t="$(now)" 'BEGIN { printf "%.3f", t + 2 }')
# sampler: every 0.2 s record the tip block, which of our transactions are confirmed, and (every 5th round) the mempool
sampler() {
  local round=0 t blk
  while [ ! -f stop.sampler ]; do
    t=$(now)
    blk=$(cli query tip --testnet-magic "$MAGIC" 2>/dev/null | jq -r .block)
    echo "$t $blk" >> blocks.txt
    cli query utxo --address "$ADDR" --output-json --testnet-magic "$MAGIC" 2>/dev/null \
      | jq -r 'keys[]' | cut -d'#' -f1 > cur.txt
    awk -v t="$t" -v b="$blk" 'NR == FNR { c[$1] = 1; next } ($1 in c) { print t, $2, $3, b }' cur.txt ids.all >> samples.txt
    if [ $((round % 5)) -eq 0 ]; then
      echo "$t $(cli query tx-mempool info --testnet-magic "$MAGIC" 2>/dev/null | jq -r '"\(.numberOfTxs) \(.sizeInBytes)"')" >> mempool.txt
    fi
    round=$((round + 1)); sleep 0.2
  done
}
# worker LANE: submit the transactions of one lane at their scheduled times (retry a refused submit for GIVEUP seconds)
worker() {
  local i=$1 k=0 sched wait start
  while [ "$k" -lt "$N" ]; do
    sched=$(awk -v t0="$T0" -v k="$k" -v r="$RATE" -v l="$LANES" -v i="$i" 'BEGIN { printf "%.3f", t0 + i / r + k * l / r }')
    wait=$(awk -v a="$sched" -v b="$(now)" 'BEGIN { d = a - b; if (d > 0) printf "%.3f", d; else print 0 }')
    [ "$wait" = 0 ] || sleep "$wait"
    start=$(date +%s)
    until cli transaction submit --tx-file "lane$i/t$k.signed" --testnet-magic "$MAGIC" > /dev/null 2> "lane$i/err"; do
      echo "$(now) $i $k $(tr '\n' ' ' < "lane$i/err" | cut -c1-200)" >> rejects.log
      if [ $(( $(date +%s) - start )) -gt "$GIVEUP" ]; then echo "$(now) $i $k GAVE UP" >> rejects.log; return; fi
      sleep 1
    done
    echo "$i $k $sched $(now)" >> submits.txt
    k=$((k + 1))
  done
}
sampler & SAMPLER=$!
WORKERS=(); for i in $(seq 0 $((LANES - 1))); do worker "$i" & WORKERS+=($!); done
wait "${WORKERS[@]}"
SUBMITTED=$(wc -l < submits.txt); END=$(now)
# wait until all submitted transactions are confirmed, or DRAIN seconds have passed
until [ "$(awk '{ if (!($2 in m) || $3 > m[$2]) m[$2] = $3 } END { for (l in m) s += m[l] + 1; print s + 0 }' samples.txt)" \
          -ge "$SUBMITTED" ] \
   || [ "$(awk -v a="$END" -v b="$(now)" 'BEGIN { print (b - a > '"$DRAIN"') }')" = 1 ]; do sleep 2; done
touch stop.sampler; wait "$SAMPLER" 2>/dev/null
B=$B RATE=$RATE LANES=$LANES SIZE=$SIZE T0=$T0 D=$DURATION PLANNED=$((N * LANES)) \
  bash /tmp/p3-scripts/sat-analyze.sh > /dev/null
T0=$T0 D=$DURATION SIZE=$SIZE bash /tmp/p3-scripts/p3-analyze.sh
