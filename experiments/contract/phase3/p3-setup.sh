#!/bin/bash
# Runs INSIDE pool 1's container. Phase 3 setup (see ../PHASE3-PLAN.md).
# Idempotent: does nothing if /tmp/p3/setup.done exists (resumable: existing keys and coins are kept).
#   keys kP kS kR (payers of the three variants) and kX (holds the reference script); funding from the genesis key utxo2:
#   8 lane coins of 60 ADA for each variant, a 10 ADA collateral coin for S and R, 20 ADA coin with the reference script;
#   registry list = [A, 47 random dummy key hashes, kS, kR] (50 keys; kS and kR last = worst case for the list search).
#   P3_DIR=/tmp/p3 P0_DIR=/tmp/p0n ./p3-setup.sh <magic>
set -eu
MAGIC=${1:?usage: p3-setup.sh <magic>}; export MAGIC
. /tmp/p3-scripts/p3-lib.sh
cd $W
[ -f setup.done ] && { echo "setup already done"; exit 0; }
cp /tmp/p3-scripts/batch100.json $W/batch100.json
for k in kP kS kR kX; do
  [ -f $k.skey ] && continue                       # resumable: keys that exist are kept
  cli address key-gen --verification-key-file $k.vkey --signing-key-file $k.skey
  cli address build --payment-verification-key-file $k.vkey --testnet-magic "$MAGIC" > $k.addr
  cli address key-hash --payment-verification-key-file $k.vkey > $k.pkh
done
# --- funding from the genesis key utxo2 (the load script must not be running) -> lane coins.
# Skipped when coll.S exists: the lane coins were already created.
if [ ! -f coll.S ]; then
G=/cardano/utxo-keys/utxo2/utxo
GA=$(cli address build --payment-verification-key-file $G.vkey --testnet-magic "$MAGIC")
read -r IN VAL < <(cli query utxo --address "$GA" --output-json --testnet-magic "$MAGIC" \
  | jq -r 'to_entries | sort_by(-.value.value.lovelace)[0] | "\(.key) \(.value.value.lovelace)"')
OUTS=(); for v in P S R; do for i in 1 2 3 4 5 6 7 8; do OUTS+=(--tx-out "$(cat k$v.addr)+60000000"); done; done  # outputs 0..23
OUTS+=(--tx-out "$(cat kS.addr)+10000000" --tx-out "$(cat kR.addr)+10000000")                                   # 24, 25
OUTS+=(--tx-out "$(cat kX.addr)+20000000" --tx-out-reference-script-file $P0/gateway_write.plutus)              # 26
# fb FEE: the funding transaction (the change is what is left of utxo2's coin after 1480 ADA of outputs and the fee)
fb() {
  cli transaction build-raw --protocol-params-file pp.json --fee "$1" --tx-in "$IN" "${OUTS[@]}" \
    --tx-out "$GA+$((VAL - 1480000000 - $1))" --out-file fund.raw > /dev/null
}
fb 1000000
F=$(cli transaction calculate-min-fee --tx-body-file fund.raw --protocol-params-file pp.json \
      --witness-count 1 --output-text | grep -o '^[0-9]*'); fb $((F + 1000))
cli transaction sign --tx-body-file fund.raw --signing-key-file $G.skey --out-file fund.signed
FID=$(txid_of fund.signed)
cli transaction submit --tx-file fund.signed --testnet-magic "$MAGIC" > /dev/null
wait_txin "$FID#26"
echo "$FID#24" > coll.S; echo "$FID#25" > coll.R; echo "$FID#26" > refscript.ref
echo "funded (tx $FID): 8 lane coins each for P, S, R; collateral coins; reference script coin $(cat refscript.ref)"
fi
# --- registry: [A, 47 dummies, kS, kR]
for i in $(seq 47); do hex28; done | jq -R . | jq -sc . > dummies.json
jq -n -c --arg a "$(cat $P0/gwA.pkh)" --arg s "$(cat kS.pkh)" --arg r "$(cat kR.pkh)" --slurpfile d dummies.json \
  '[$a] + $d[0] + [$s, $r]' > list50.json
set_registry list50.json
echo "registry now has $(registry_list | jq length) keys, coin $(cat reg.ref)"
touch setup.done
