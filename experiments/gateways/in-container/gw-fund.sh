#!/bin/bash
# Runs INSIDE pool 1's container (started by ../gateways.sh). One transaction from the funded genesis
# key utxo1 that pays LOVELACE to every gateway address given as an argument, then waits until it is
# in a block.
#
# Usage:  gw-fund.sh <magic> <address> [<address> ...]
# Environment:  LOVELACE  amount per address (default 100000000 = 100 ADA)
set -u
export CARDANO_NODE_SOCKET_PATH=/node.socket
cli() { cardano-cli conway "$@"; }

MAGIC=$1; shift
LOVELACE=${LOVELACE:-100000000}
KEY=/cardano/utxo-keys/utxo1/utxo
FEE=1000000
WORKDIR=/tmp/gw-fund; rm -rf $WORKDIR; mkdir -p $WORKDIR; cd $WORKDIR || exit 1

# the payer: its address and its biggest UTxO (the change goes back to the payer)
PAYER=$(cli address build --payment-verification-key-file $KEY.vkey --testnet-magic "$MAGIC")
read -r IN VAL < <(cli query utxo --address "$PAYER" --output-json --testnet-magic "$MAGIC" \
  | jq -r 'to_entries | sort_by(-.value.value.lovelace)[0] | "\(.key) \(.value.value.lovelace)"')

# one output per gateway address
OUTS=(); TOTAL=0
for addr in "$@"; do
  OUTS+=(--tx-out "$addr+$LOVELACE"); TOTAL=$((TOTAL + LOVELACE))
done

cli transaction build-raw --fee $FEE --tx-in "$IN" --tx-out "$PAYER+$((VAL - TOTAL - FEE))" "${OUTS[@]}" \
    --out-file fund.raw >/dev/null || exit 1
cli transaction sign --tx-body-file fund.raw --signing-key-file $KEY.skey --out-file fund.signed || exit 1
ID=$(cli transaction txid --tx-file fund.signed | grep -o '[0-9a-f]\{64\}')
cli transaction submit --tx-file fund.signed --testnet-magic "$MAGIC" >/dev/null 2>&1 || {
  echo "funding transaction refused" >&2; exit 1
}
# the change output (#1) shows up when the transaction is in a block
until cli query utxo --tx-in "$ID#1" --output-json --testnet-magic "$MAGIC" 2>/dev/null | grep -q lovelace; do
  sleep 0.5
done
echo "funded $# gateways with $LOVELACE lovelace each (transaction $ID)"
