#!/bin/bash
# Runs INSIDE pool 1's container (fresh.sh copies it to /tmp/p0-scripts/). Funds the two demo gateways once, from the
# dedicated administrator (same amounts as p0-write.sh): 20 ADA to pay with + 5 ADA only for collateral, each.
#   P0_DIR=/tmp/p0n ./p1-fund.sh <magic>        idempotent: does nothing if the work dir has the file "funded"
# It waits (wait_settled in p0-lib.sh) until the funding is in a block AND one more block is on top, and sends the
# same signed transaction again if it gets lost (a block that carried it can be replaced by a block of another pool).
# Safe to run again after a failure: if an earlier run sent the funding (fund.signed) and that transaction is in a
# block, the next run only writes the file "funded" and does not fund a second time.
set -eu
MAGIC=${1:?usage: p1-fund.sh <magic>}
. /tmp/p0-scripts/p0-lib.sh                       # sets W (= $P0_DIR), cli, tx_visible, wait_settled ...; cd to W
[ -f funded ] && { echo "gateways A and B already funded"; exit 0; }
ADMIN=$(cat admin.addr)
if [ -f fund.signed ]; then                       # an earlier run sent the funding: is it in a block now?
  OLD_ID=$(cli transaction txid --tx-file fund.signed | grep -o '[0-9a-f]\{64\}')
  if tx_visible "$OLD_ID"; then
    touch funded; echo "gateways A and B were funded by an earlier run (tx $OLD_ID)"; exit 0
  fi
fi

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
wait_settled "$FID" fund.signed || { echo "funding tx not seen"; exit 1; }
touch funded; echo "funded gateways A and B (tx $FID)"
