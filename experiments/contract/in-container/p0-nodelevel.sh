#!/bin/bash
# Runs INSIDE pool 1's container, after p0-registry.sh and p0-write.sh.
# Phase 0, task 1: the NODE (ledger) must refuse a data tx of gateway B, not only the client-side `transaction build`.
# Both transactions are made with `transaction build-raw` and made-up execution units: nothing checks the script until submit.
#   p0-nodelevel.sh <magic>
set -eu
MAGIC=$1; . /tmp/p0-scripts/p0-lib.sh
REG=$(cat registry.ref)
echo "== protocol parameters used: fee/byte $(jq .txFeePerByte pp.json), fixed $(jq .txFeeFixed pp.json), price mem $(jq .executionUnitPrices.priceMemory pp.json), price steps $(jq .executionUnitPrices.priceSteps pp.json), collateral % $(jq .collateralPercentage pp.json)"
echo "== declared execution units (cli order steps,memory): $EXU"

for g in B A; do
  gw_utxos $g
  mk_data_tx $g n$g "$PAY" "$PAYLOV" "$PAYTOK" "$COLL" "$COLLLOV" "$REG"
  echo "--- gateway $g: tx $TXID  size $SIZE bytes  fee $FEE lovelace  (spends $PAY, collateral $COLL)"
  MEM=$EXU_MEM; STP=$EXU_STEPS
  awk -v s=$SIZE -v m=$MEM -v t=$STP -v pm=$(jq .executionUnitPrices.priceMemory pp.json) -v pt=$(jq .executionUnitPrices.priceSteps pp.json) \
    'BEGIN{printf "    fee check: %d (size*1) + %.1f (memory*%s) + %.1f (steps*%s) = %.1f lovelace\n", s, m*pm, pm, t*pt, pt, s+m*pm+t*pt}'
  echo "    units the node measures for this tx (before submit):"
  cli transaction calculate-plutus-script-cost online --testnet-magic "$MAGIC" --tx-file n$g.signed 2>&1 | jq -c '.[] | {memory: .executionUnits.memory, steps: .executionUnits.steps}' 2>/dev/null || echo "    (script fails: no units)"
  if OUT=$(submit_tx n$g); then
    if [ $g = B ]; then echo "    UNEXPECTED: gateway B was accepted"; exit 1; fi
    echo "    ACCEPTED by the node: $OUT" | head -c 300; echo; wait_tx "$TXID" && echo "    now in a block"
    cli query utxo --tx-in "$TXID#0" --output-json --testnet-magic "$MAGIC" | jq -c '.[] | .value'
  else
    if [ $g = A ]; then echo "    UNEXPECTED: gateway A was refused: $(echo "$OUT" | short_err)"; exit 1; fi
    echo "$OUT" > n$g.refused.txt
    echo "    REFUSED by the node at submit (message shortened; full text in $W/n$g.refused.txt):"
    echo "$OUT" | grep -o 'ConwayUtxowFailure.*FailedUnexpectedly (PlutusFailure' | head -1
    echo "$OUT" | grep -o 'The plutus evaluation error is:[^\\]*\\n[^\\]*' | head -1
    echo "$OUT" | grep -o 'Error while submitting tx: [A-Za-z]*' | head -1
  fi
done
