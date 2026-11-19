#!/bin/bash
# Runs INSIDE pool 1's container (started by ../saturate.sh) or a gateway's container (../../gateways).
# One step of the saturation test: submit sensor-style metadata transactions at a fixed rate for
# DURATION seconds and find out when each one ended up in a block.
#
# The transactions are built and signed BEFORE the step (cardano-cli needs ~0.5 s of CPU per
# transaction, which would otherwise distort the timing). Each lane is a chain: a transaction spends
# the output of the previous one of its lane, so no transaction waits for a block before the next one
# can be sent. A lane worker submits its transactions at the planned times; if the node refuses one
# (mempool full) the worker retries it every second, which is what a sensor gateway would do.
#
# Confirmation: once a second the UTxOs of the address are read. The UTxO of a lane is the output of
# its newest transaction that is in a block; its position in the lane says how many transactions of
# the lane are confirmed. The confirmation time of a transaction is the first reading that shows it.
#
# Output: the step's files in /tmp/sat/step/ (txs.csv, summary.csv, rejects.log, ...); on stdout the
# summary.csv (header line + one row), printed by sat-analyze.sh.
#
# Environment (default):
#   MAGIC      network magic (required)
#   B          readings per transaction (required)
#   RATE       transactions per second, all lanes together (required)
#   DURATION   seconds of submitting                        (120)
#   LANES      independent chains of transactions           (4)
#   DRAIN      seconds to wait for the rest after the last submit  (300)
#   GIVEUP     a transaction that cannot be submitted for this long ends its lane (seconds)  (60)
#   DRY_RUN    1 = build 3 transactions per lane, print their size and the fee, submit nothing
#   KEY        key files without extension (.vkey/.skey) of the paying address
#              (/cardano/utxo-keys/utxo2/utxo; a gateway test uses the gateway's own key)
#   START_AT   epoch seconds at which to start submitting (so several nodes start together)
#              (default: 2 seconds from now)
set -u
MAGIC=${MAGIC:?}
B=${B:?readings per transaction}
RATE=${RATE:?transactions per second, all lanes together}
DURATION=${DURATION:-120}
LANES=${LANES:-4}
DRAIN=${DRAIN:-300}
GIVEUP=${GIVEUP:-60}
DRY_RUN=${DRY_RUN:-}
KEY=${KEY:-/cardano/utxo-keys/utxo2/utxo}
export CARDANO_NODE_SOCKET_PATH=/node.socket

TX_LIMIT=16384          # protocol limit of a transaction, in bytes
MIN_LANE_VALUE=2000000  # a lane stops when its UTxO would fall below this (lovelace)

# its own folder: the load and the other measurements use /tmp too
WORKDIR=/tmp/sat/step; rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"; cd "$WORKDIR" || exit 1

cli() { cardano-cli conway "$@"; }
now() { date +%s.%N; }
ADDR=$(cli address build --payment-verification-key-file $KEY.vkey --testnet-magic "$MAGIC")

# --- the metadata: B readings of 40 characters (42 bytes each in CBOR)
jq -n --argjson n "$B" \
  '{"1000": [range($n) | ("id=\(. % 1000) t=1730000000 temp=23.417 hum=48.2 ok" + "                                        ")[:40]]}' \
  > meta.json

# --- lanes: the UTxOs with the most funds
cli query protocol-parameters --testnet-magic "$MAGIC" --out-file pp.json
cli query utxo --address "$ADDR" --output-json --testnet-magic "$MAGIC" \
  | jq -r --argjson l "$LANES" \
      'to_entries | sort_by(-.value.value.lovelace) | .[:$l][] | "\(.key) \(.value.value.lovelace)"' > lanes.txt
[ "$(wc -l < lanes.txt)" -ge "$LANES" ] || {
  echo "fewer than $LANES UTxOs at utxo2 (is the load's split done?)" >&2; exit 1
}

# --- the fee: all transactions of a step have the same size, so one calculation is enough
read -r IN0 VAL0 < <(head -1 lanes.txt)
cli transaction build-raw --fee 200000 --tx-in "$IN0" --tx-out "$ADDR+$((VAL0 - 200000))" \
    --metadata-json-file meta.json --out-file draft.raw >/dev/null || exit 1
MINFEE=$(cli transaction calculate-min-fee --tx-body-file draft.raw --protocol-params-file pp.json \
           --witness-count 1 | grep -o '[0-9]\+' | head -1)
FEE=$((MINFEE + 1000))
# transactions per lane (rounded up)
N=$(awk -v r="$RATE" -v d="$DURATION" -v l="$LANES" \
      'BEGIN { n = r * d / l; printf "%d", (n == int(n)) ? n : int(n) + 1 }')
[ "$DRY_RUN" = 1 ] && N=3

# --- build and sign the chains, the lanes in parallel
build_lane() {          # build_lane <lane> <first input> <its value>
  local i=$1 in=$2 val=$3 k id
  mkdir -p "lane$i"; : > "lane$i/ids"
  for k in $(seq 0 $((N - 1))); do
    val=$((val - FEE))
    [ "$val" -gt "$MIN_LANE_VALUE" ] || { echo "lane $i: funds run out at tx $k" >&2; return 1; }
    cli transaction build-raw --fee "$FEE" --tx-in "$in" --tx-out "$ADDR+$val" \
        --metadata-json-file meta.json --out-file "lane$i/tx.raw" >/dev/null || return 1
    cli transaction sign --tx-body-file "lane$i/tx.raw" --signing-key-file $KEY.skey \
        --out-file "lane$i/tx$k.signed" || return 1
    id=$(cli transaction txid --tx-file "lane$i/tx$k.signed" | grep -o '[0-9a-f]\{64\}')
    echo "$id $i $k" >> "lane$i/ids"
    in="$id#0"                                    # the next transaction spends this one's output
  done
}

BUILD_START=$(now)
i=0
while read -r txin val; do
  build_lane "$i" "$txin" "$val" &
  i=$((i + 1))
done < <(head -n "$LANES" lanes.txt)
wait
cat lane*/ids > ids.all
[ "$(wc -l < ids.all)" -eq $((N * LANES)) ] || {
  echo "building failed: $(wc -l < ids.all) of $((N * LANES)) transactions" >&2; exit 1
}
SIZE=$(( $(jq -r .cborHex lane0/tx0.signed | wc -c) / 2 ))
build_seconds=$(awk -v a="$BUILD_START" -v b="$(now)" 'BEGIN { printf "%.0f", b - a }')
echo "built $((N * LANES)) transactions of $SIZE bytes in $build_seconds s (fee $FEE, limit $TX_LIMIT bytes)" >&2
if [ "$DRY_RUN" = 1 ]; then echo "dry run: nothing submitted"; echo "size_bytes=$SIZE fee=$FEE"; exit 0; fi

# --- the step
: > submits.txt; : > rejects.log; : > samples.txt; : > mempool.txt
# a moment for the workers to start; START_AT: the same start time for several nodes
T0=${START_AT:-$(awk -v t="$(now)" 'BEGIN { printf "%.3f", t + 2 }')}

# Reads the UTxOs of the address every 0.3 s: samples.txt gets "<time> <lane> <k>" for each lane's newest
# confirmed transaction; every 5th round it also records the mempool size (mempool.txt).
sampler() {
  local round=0 t
  while [ ! -f stop.sampler ]; do
    t=$(now)
    cli query utxo --address "$ADDR" --output-json --testnet-magic "$MAGIC" 2>/dev/null \
      | jq -r 'keys[]' | cut -d'#' -f1 > cur.txt
    awk -v t="$t" 'NR == FNR { c[$1] = 1; next } ($1 in c) { print t, $2, $3 }' cur.txt ids.all >> samples.txt
    if [ $((round % 5)) -eq 0 ]; then
      echo "$t $(cli query tx-mempool info --testnet-magic "$MAGIC" 2>/dev/null \
                   | jq -r '"\(.numberOfTxs) \(.sizeInBytes)"')" >> mempool.txt
    fi
    round=$((round + 1)); sleep 0.3
  done
}

# Submits the transactions of one lane at their planned times (submits.txt: "<lane> <k> <planned> <real>").
worker() {              # worker <lane>
  local i=$1 k=0 planned pause started
  while [ "$k" -lt "$N" ]; do
    planned=$(awk -v t0="$T0" -v k="$k" -v r="$RATE" -v l="$LANES" -v i="$i" \
                'BEGIN { printf "%.3f", t0 + i / r + k * l / r }')
    pause=$(awk -v a="$planned" -v b="$(now)" 'BEGIN { d = a - b; if (d > 0) printf "%.3f", d; else print 0 }')
    [ "$pause" = 0 ] || sleep "$pause"
    started=$(date +%s)
    until cli transaction submit --tx-file "lane$i/tx$k.signed" --testnet-magic "$MAGIC" > /dev/null 2> "lane$i/err"; do
      echo "$(now) $i $k $(tr '\n' ' ' < "lane$i/err" | cut -c1-200)" >> rejects.log
      if [ $(( $(date +%s) - started )) -gt "$GIVEUP" ]; then
        echo "$(now) $i $k GAVE UP" >> rejects.log; return
      fi
      sleep 1
    done
    echo "$i $k $planned $(now)" >> submits.txt
    k=$((k + 1))
  done
}

# number of transactions seen in blocks so far (per lane: highest confirmed k + 1, summed)
confirmed_count() {
  awk '{ if (!($2 in m) || $3 > m[$2]) m[$2] = $3 } END { for (l in m) s += m[l] + 1; print s + 0 }' samples.txt
}

# prints 1 when more than DRAIN seconds have passed since $END
waited_too_long() {
  awk -v a="$END" -v b="$(now)" -v drain="$DRAIN" 'BEGIN { print (b - a > drain) }'
}

sampler & SAMPLER=$!
WORKERS=()
for i in $(seq 0 $((LANES - 1))); do worker "$i" & WORKERS+=($!); done
wait "${WORKERS[@]}"

# --- wait for the rest to get into blocks
SUBMITTED=$(wc -l < submits.txt)
END=$(now)
until [ "$(confirmed_count)" -ge "$SUBMITTED" ] || [ "$(waited_too_long)" = 1 ]; do sleep 2; done
touch stop.sampler; wait "$SAMPLER" 2>/dev/null

# --- results (sat-analyze.sh, next to this file or in /tmp)
B=$B RATE=$RATE LANES=$LANES SIZE=$SIZE T0=$T0 D=$DURATION PLANNED=$((N * LANES)) bash "$(dirname "$0")/sat-analyze.sh"
