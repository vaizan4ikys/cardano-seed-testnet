#!/bin/bash
# Runs INSIDE pool 1's container (started by ../p0.sh), after p0-registry.sh.
# Phase 0, step 2: one data transaction (metadata + one RECEIPT token minted under the gateway_write policy)
# from gateway A (enrolled: must pass) and from gateway B (not enrolled: must be refused).
#   p0-write.sh <magic>       needs gateway_write.plutus in the work dir $P0_DIR (default /tmp/p0): the Aiken policy
#                             with its two parameters applied
set -eu
export CARDANO_NODE_SOCKET_PATH=/node.socket
cli() { cardano-cli conway "$@"; }
MAGIC=$1
W=${P0_DIR:-/tmp/p0}; cd $W
ADMIN=$(cat admin.addr); REG=$(cat registry.ref)
PW=$(cli transaction policyid --script-file gateway_write.plutus)
RHEX=$(printf 'RECEIPT' | od -An -tx1 | tr -d ' \n')
for g in A B; do cli address build --payment-verification-key-file gw$g.vkey --testnet-magic "$MAGIC" > gw$g.addr; done

# wait_tx TXID: wait until output 0 of the transaction is visible (= it is in a block)
wait_tx() {
  until cli query utxo --tx-in "$1#0" --output-json --testnet-magic "$MAGIC" 2>/dev/null | grep -q lovelace; do
    sleep 0.5
  done
}

# fund both gateways once (from the dedicated administrator, not from utxo1): 20 ADA to pay with + 5 ADA only for collateral each
if [ ! -f funded ]; then
  read -r IN VAL < <(cli query utxo --address "$ADMIN" --output-json --testnet-magic "$MAGIC" \
    | jq -r 'to_entries | map(select(.value.value|keys==["lovelace"])) | sort_by(-.value.value.lovelace)[0]
             | "\(.key) \(.value.value.lovelace)"')
  FEE=1000000; OUT=50000000
  cli transaction build-raw --fee $FEE --tx-in "$IN" \
    --tx-out "$(cat gwA.addr)+20000000" --tx-out "$(cat gwA.addr)+5000000" \
    --tx-out "$(cat gwB.addr)+20000000" --tx-out "$(cat gwB.addr)+5000000" \
    --tx-out "$ADMIN+$((VAL - OUT - FEE))" --out-file fund.raw >/dev/null
  cli transaction sign --tx-body-file fund.raw --signing-key-file admin.skey --out-file fund.signed
  FID=$(cli transaction txid --tx-file fund.signed | grep -o '[0-9a-f]\{64\}')
  cli transaction submit --tx-file fund.signed --testnet-magic "$MAGIC" >/dev/null
  wait_tx "$FID"; touch funded; echo "funded gateways A and B (tx $FID)"
fi

data_tx() {   # data_tx A|B
  local g=$1 pkh addr
  pkh=$(cat gw$g.pkh); addr=$(cat gw$g.addr)
  cli query utxo --address "$addr" --output-json --testnet-magic "$MAGIC" > gw$g.utxo.json
  local pay coll
  # pay = the biggest pure-lovelace coin, coll = the smallest one (collateral)
  pay=$(jq -r 'to_entries | map(select(.value.value|keys==["lovelace"]))
               | sort_by(-.value.value.lovelace)[0].key' gw$g.utxo.json)
  coll=$(jq -r 'to_entries | map(select(.value.value|keys==["lovelace"]))
                | sort_by(.value.value.lovelace)[0].key' gw$g.utxo.json)
  printf '{"1000":{"sensor":"AGRI_001","t":"%s","temp":2450,"scale":100}}\n' "$(date -u +%FT%TZ)" > meta$g.json
  local h; h=$(sha256sum meta$g.json | cut -d' ' -f1)
  printf '{"bytes":"%s"}\n' "$h" > red$g.json
  echo "--- gateway $g ($pkh): pay $pay, collateral $coll, batch hash $h"
  if cli transaction build --tx-in "$pay" --tx-in-collateral "$coll" --read-only-tx-in-reference "$REG" \
       --mint "1 $PW.$RHEX" --mint-script-file gateway_write.plutus --mint-redeemer-file red$g.json \
       --required-signer-hash "$pkh" --metadata-json-file meta$g.json \
       --change-address "$addr" --testnet-magic "$MAGIC" --out-file d$g.raw > build$g.out 2>&1; then
    cat build$g.out
    cli transaction sign --tx-body-file d$g.raw --signing-key-file gw$g.skey --out-file d$g.signed
    local id; id=$(cli transaction txid --tx-file d$g.signed | grep -o '[0-9a-f]\{64\}')
    if cli transaction submit --tx-file d$g.signed --testnet-magic "$MAGIC" > sub$g.out 2>&1; then
      wait_tx "$id"; echo "ACCEPTED: tx $id is in a block"
      cli query utxo --tx-in "$id#0" --output-json --testnet-magic "$MAGIC" | jq -c '.[] | .value'
    else echo "REFUSED at submit:"; head -c 600 sub$g.out; fi
  else echo "REFUSED while building (script failed):"; head -c 700 build$g.out; echo; fi
}

data_tx A
data_tx B
