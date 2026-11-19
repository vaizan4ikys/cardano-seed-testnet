#!/bin/bash
# Runs INSIDE pool 1's container. Phase 3, part A: the cost of ONE transaction per variant (P plain, S script inside, R reference
# script) and registry size N = 3, 10, 50: size, fee, execution units MEASURED by the node (calculate-plutus-script-cost online),
# the units declared afterwards (measured + 10 %). Nothing is submitted except the registry changes. Ends with N = 50 and writes
# $W/exu.steps $W/exu.mem (declared units for part B). Result: results/costs.csv
#   ./p3-costs.sh <magic>
set -eu
MAGIC=${1:?usage: p3-costs.sh <magic>}; export MAGIC
. /tmp/p3-scripts/p3-lib.sh
cd $W
OUT=results/costs.csv
rm -f exu.steps exu.mem
echo "variant,registry_keys,tx_bytes,fee_lovelace,measured_steps,measured_mem,declared_steps,declared_mem,script_bytes_in_tx" > $OUT
lane0() {   # first lane coin of the current variant (the biggest coin that is not the collateral): sets IN VAL TOK
  cli query utxo --address "$ADDR" --output-json --testnet-magic "$MAGIC" \
    | jq -r --arg coll "${COLL:-none}" --arg pw "$PW" --arg t "$RHEX" \
        'to_entries | map(select(.key != $coll)) | sort_by(-.value.value.lovelace)[0]
         | "\(.key) \(.value.value.lovelace) \(.value.value[$pw][$t] // 0)"' > lane0.txt
  read -r IN VAL TOK < lane0.txt
}
# plain transaction
use_variant P; lane0; EXU=""
F=$(min_fee "$IN" "$VAL" "$TOK"); F=$((F + 1000)); mk_tx "$IN" "$VAL" "$TOK" "$F" cost-P
echo "P,0,$(size_of cost-P.signed),$F,0,0,0,0,0" | tee -a $OUT
for N in 3 10 50; do
  jq -n -c --arg a "$(cat $P0/gwA.pkh)" --arg s "$(cat kS.pkh)" --arg r "$(cat kR.pkh)" \
    --slurpfile d dummies.json --argjson n "$N" '[$a] + $d[0][:($n-3)] + [$s, $r]' > list$N.json
  set_registry list$N.json
  echo "registry: $(registry_list | jq length) keys"
  for v in S R; do
    use_variant $v; lane0
    EXU="(5000000000,10000000)"                               # generous, only to measure
    mk_tx "$IN" "$VAL" "$TOK" 500000 cost-$v-measure
    cli transaction calculate-plutus-script-cost online --tx-file cost-$v-measure.signed \
      --testnet-magic "$MAGIC" --socket-path /node.socket --out-file cost-$v.json > /dev/null
    # MS / MM = the steps / memory the node measured; DS / DM = declared: measured + 10 %, rounded up
    MS=$(jq -r '.[0].executionUnits.steps // .[0].exUnitsSteps // .[0].steps' cost-$v.json)
    MM=$(jq -r '.[0].executionUnits.memory // .[0].exUnitsMem // .[0].memory' cost-$v.json)
    DS=$(( (MS * 110 + 99) / 100 )); DM=$(( (MM * 110 + 99) / 100 )); EXU="($DS,$DM)"
    F=$(min_fee "$IN" "$VAL" "$TOK"); F=$((F + 1000)); mk_tx "$IN" "$VAL" "$TOK" "$F" cost-$v-$N
    echo "$v,$N,$(size_of cost-$v-$N.signed),$F,$MS,$MM,$DS,$DM,$([ $v = S ] && echo $SCRIPT_BYTES || echo 0)" | tee -a $OUT
    if [ "$N" = 50 ]; then    # part B declares the larger of the S and R values
      { [ ! -f exu.steps ] || [ "$DS" -gt "$(cat exu.steps)" ]; } && echo "$DS" > exu.steps
      { [ ! -f exu.mem ] || [ "$DM" -gt "$(cat exu.mem)" ]; } && echo "$DM" > exu.mem
    fi
  done
done
echo "declared units for part B (N=50, larger of S and R, +10 %): $(cat exu.steps) steps, $(cat exu.mem) memory"
