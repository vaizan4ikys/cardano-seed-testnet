#!/bin/bash
# Runs INSIDE pool 1's container (fresh.sh copies it to /tmp/p0-scripts/). Funds the two demo gateways once, from the
# dedicated administrator (same amounts as p0-write.sh): 20 ADA to pay with + 5 ADA only for collateral, each.
#   P0_DIR=/tmp/p0n ./p1-fund.sh <magic>        idempotent: does nothing if the work dir has the file "funded"
set -eu
export CARDANO_NODE_SOCKET_PATH=/node.socket
cli() { cardano-cli conway "$@"; }
MAGIC=${1:?usage: p1-fund.sh <magic>}
cd "${P0_DIR:-/tmp/p0}"
[ -f funded ] && { echo "gateways A and B already funded"; exit 0; }
ADMIN=$(cat admin.addr)

# the biggest pure-lovelace coin of the administrator: IN = txid#index, VAL = its lovelace
read -r IN VAL < <(cli query utxo --address "$ADMIN" --output-json --testnet-magic "$MAGIC" \
  | jq -r 'to_entries | map(select(.value.value|keys==["lovelace"])) | sort_by(-.value.value.lovelace)[0]
           | "\(.key) \(.value.value.lovelace)"')

# one transaction: A gets 20 ADA + 5 ADA, B gets 20 ADA + 5 ADA, the rest (minus the fee) goes back to the administrator
FEE=1000000; OUT=50000000
cli transaction build-raw --fee $FEE --tx-in "$IN" \
  --tx-out "$(cat gwA.addr)+20000000" --tx-out "$(cat gwA.addr)+5000000" \
  --tx-out "$(cat gwB.addr)+20000000" --tx-out "$(cat gwB.addr)+5000000" \
  --tx-out "$ADMIN+$((VAL - OUT - FEE))" --out-file fund.raw > /dev/null
cli transaction sign --tx-body-file fund.raw --signing-key-file admin.skey --out-file fund.signed
FID=$(cli transaction txid --tx-file fund.signed | grep -o '[0-9a-f]\{64\}')
cli transaction submit --tx-file fund.signed --testnet-magic "$MAGIC" > /dev/null

# wait (up to 60 s) until the funding transaction is in a block
n=0
until cli query utxo --tx-in "$FID#0" --output-json --testnet-magic "$MAGIC" 2>/dev/null | grep -q lovelace; do
  sleep 0.5; n=$((n+1))
  [ $n -gt 120 ] && { echo "funding tx not seen"; exit 1; }
done
touch funded; echo "funded gateways A and B (tx $FID)"
