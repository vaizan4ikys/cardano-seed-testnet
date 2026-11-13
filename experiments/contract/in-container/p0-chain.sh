#!/bin/bash
# Runs INSIDE pool 1's container. Phase 0, task 2: CHAINED script transactions (what the load generator does).
# Gateway A builds N data transactions, each spending the change output of the one before (same reference input,
# the same collateral coin, which no tx spends), BEFORE any is in a block; then submits them one after the other as fast
# as it can; then we watch in which blocks they end up.
#   p0-chain.sh <magic> [N=5]
set -eu
MAGIC=$1; N=${2:-5}; . /tmp/p0-scripts/p0-lib.sh
REG=$(cat registry.ref)
gw_utxos A
echo "== start: A spends $PAY ($PAYLOV lovelace, $PAYTOK receipts), collateral $COLL (never spent by the chain)"
pay=$PAY; lov=$PAYLOV; tok=$PAYTOK; ids=(); t0=$(now_ms)
for i in $(seq 1 $N); do
  mk_data_tx A c$i "$pay" "$lov" "$tok" "$COLL" "$COLLLOV" "$REG"
  ids+=("$TXID"); echo "   built tx $i: $TXID size $SIZE fee $FEE (spends $pay)"
  pay=$CHANGE; lov=$NEXTLOV; tok=$NEXTTOK
done
echo "== all $N built offline in $(( $(now_ms) - t0 )) ms; now submitting in a row"
B0=$(tip_block); T0=$(now_ms)
for i in $(seq 1 $N); do
  OUT=$(submit_tx c$i) && r=ok || r="REFUSED: $(echo "$OUT" | head -c 400)"
  echo "   submit tx $i at +$(( $(now_ms) - T0 )) ms: $r"
done
echo "== submitted all in $(( $(now_ms) - T0 )) ms (tip block was $B0); watching for them to appear in blocks"
declare -A seen=()
while [ "${#seen[@]}" -lt "$N" ] && [ $(( $(now_ms) - T0 )) -lt 90000 ]; do
  for i in $(seq 1 $N); do
    [ -n "${seen[$i]:-}" ] && continue
    # a spent change output is gone from the UTxO set, so we watch the node's mempool instead: the tx leaves it when a block takes it
    if ! cli query tx-mempool tx-exists "${ids[$((i-1))]}" --testnet-magic "$MAGIC" | grep -q true; then seen[$i]="block $(tip_block) at +$(( $(now_ms) - T0 )) ms"; fi
  done
  sleep 0.2
done
for i in $(seq 1 $N); do echo "   tx $i ${ids[$((i-1))]}: ${seen[$i]:-NOT SEEN within 90 s}"; done
echo "== distinct blocks used: $(for i in $(seq 1 $N); do echo "${seen[$i]:-x}" | cut -d' ' -f1-2; done | sort -u | wc -l)"
echo "== (tx leaves the mempool = it is in the block named above; final proof is the receipt count below: $((PAYTOK + N)) expected)"
gw_utxos A; echo "== A now: $PAY ($PAYLOV lovelace, $PAYTOK receipts)"
