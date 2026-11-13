#!/bin/bash
# Runs INSIDE pool 1's container, after the registry exists. Phase 0: two guards, both proven at the node.
#   G1  the registry token cannot be minted a second time (one-shot policy registry_mint)
#   G2  registry coins of an OLD policy (from the first runs, and a look-alike made here) are inert: a data tx of gateway A
#       that references one of them is refused, because gateway_write only trusts the registry policy it was built with
#   p0-guards.sh <magic>        (OLD_REGISTRY_DIRS="/tmp/p0 /tmp/p0v" = work dirs of earlier runs whose registry.ref to try)
set -eu
MAGIC=$1; . /tmp/p0-scripts/p0-lib.sh
REG=$(cat registry.ref); RPOL=$(cat policy.id); TOK=$(cat token.hex); ADMIN=$(cat admin.addr)
echo "== current registry: coin $REG, policy $RPOL"

echo "== G1: try to mint a second GW_REGISTRY token under the one-shot policy (admin spends another coin)"
read -r PAYC PAYL < <(cli query utxo --address "$ADMIN" --output-json --testnet-magic "$MAGIC" \
  | jq -r 'to_entries | map(select(.value.value|keys==["lovelace"])) | sort_by(-.value.value.lovelace)[0] | "\(.key) \(.value.value.lovelace)"')
COLLC=$(cat admin.coll); COLLL=$(cli query utxo --tx-in "$COLLC" --output-json --testnet-magic "$MAGIC" | jq -r '.[].value.lovelace')
FEE=1000000; TC=1500000
cli transaction build-raw --protocol-params-file pp.json --fee $FEE --tx-in "$PAYC" --tx-in-collateral "$COLLC" \
  --tx-total-collateral $TC --tx-out-return-collateral "$ADMIN+$((COLLL - TC))" \
  --mint "1 $RPOL.$TOK" --mint-script-file registry_mint.plutus --mint-redeemer-value 0 --mint-execution-units "(100000000,500000)" \
  --tx-out "$ADMIN+$((PAYL - FEE))+1 $RPOL.$TOK" --out-file dup.raw > /dev/null
cli transaction sign --tx-body-file dup.raw --signing-key-file admin.skey --out-file dup.signed
if OUT=$(submit_tx dup); then echo "   UNEXPECTED: a second registry token was minted"; exit 1; fi
echo "   REFUSED by the node:"; echo "$OUT" | plutus_err

echo "== G2: old-policy registry coins"
# a look-alike made the way the first version of the registry was made: token GW_REGISTRY under a plain 'admin signs'
# native script, datum = [gateway A of THIS run]. It has the right name and lists A, only its policy is not the registry policy.
if [ ! -f decoy.ref ] || ! tx_visible "$(cut -d'#' -f1 decoy.ref)"; then
  echo "{\"type\":\"sig\",\"keyHash\":\"$(cat admin.pkh)\"}" > decoy.script
  DPOL=$(cli transaction policyid --script-file decoy.script)
  printf '{"list":[{"bytes":"%s"}]}\n' "$(cat gwA.pkh)" > decoy.datum.json
  read -r PAYC PAYL < <(cli query utxo --address "$ADMIN" --output-json --testnet-magic "$MAGIC" \
    | jq -r 'to_entries | map(select(.value.value|keys==["lovelace"])) | sort_by(-.value.value.lovelace)[0] | "\(.key) \(.value.value.lovelace)"')
  db() { cli transaction build-raw --fee "$1" --tx-in "$PAYC" --tx-out "$ADMIN+5000000+1 $DPOL.$TOK" --tx-out-inline-datum-file decoy.datum.json \
           --tx-out "$ADMIN+$((PAYL - 5000000 - $1))" --mint "1 $DPOL.$TOK" --minting-script-file decoy.script --out-file decoy.raw > /dev/null; }
  db 300000; f=$(cli transaction calculate-min-fee --tx-body-file decoy.raw --protocol-params-file pp.json --witness-count 2 --output-text | grep -o '^[0-9]*'); db "$f"
  cli transaction sign --tx-body-file decoy.raw --signing-key-file admin.skey --out-file decoy.signed
  DID=$(cli transaction txid --tx-file decoy.signed | grep -o '[0-9a-f]\{64\}')
  submit_tx decoy > /dev/null; wait_tx "$DID"; echo "$DID#0" > decoy.ref
  echo "$(date -u +%FT%TZ) $DID#0 policy=$DPOL OBSOLETE look-alike (native 'admin signs' policy), made only to test inertness" >> registry.history
fi
REFS="$(cat decoy.ref)"
for d in ${OLD_REGISTRY_DIRS:-}; do [ -f "$d/registry.ref" ] && [ "$d" != "$PWD" ] && REFS="$REFS $(cat $d/registry.ref)"; done
for r in $REFS; do
  info=$(cli query utxo --tx-in "$r" --output-json --testnet-magic "$MAGIC" | jq -c '.[] | {policies: (.value | keys | map(select(. != "lovelace"))), datum: .inlineDatum}' || true)
  [ -n "$info" ] || { echo "   (coin $r is gone, skipped)"; continue; }
  gw_utxos A; mk_data_tx A guard "$PAY" "$PAYLOV" "$PAYTOK" "$COLL" "$COLLLOV" "$r"
  echo "   data tx of A referencing old coin $r  $info"
  if OUT=$(submit_tx guard); then echo "   UNEXPECTED: accepted"; exit 1; fi
  echo "   REFUSED by the node:"; echo "$OUT" | plutus_err | sed 's/^/     /'
done
gw_utxos A; mk_data_tx A ctl "$PAY" "$PAYLOV" "$PAYTOK" "$COLL" "$COLLLOV" "$REG"
echo "== control: the same tx of A with the CURRENT registry passes the script (units measured by the node, tx not submitted): $(cli transaction calculate-plutus-script-cost online --testnet-magic "$MAGIC" --tx-file ctl.signed | jq -c '.[] | {memory: .executionUnits.memory, steps: .executionUnits.steps}')"
