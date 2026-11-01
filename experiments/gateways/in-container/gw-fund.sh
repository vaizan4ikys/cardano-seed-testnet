#!/bin/bash
# Runs INSIDE pool 1's container (started by ../gateways.sh). One transaction from the funded key utxo1 that pays
# LOVELACE to every gateway address given as an argument, then waits until it is in a block.
#   gw-fund.sh <magic> <address> [<address> ...]        LOVELACE (default 100000000 = 100 ADA) per address
set -u
export CARDANO_NODE_SOCKET_PATH=/node.socket
cli() { cardano-cli conway "$@"; }
MAGIC=$1; shift
LOV=${LOVELACE:-100000000}
KEY=/cardano/utxo-keys/utxo1/utxo
W=/tmp/gw-fund; rm -rf $W; mkdir -p $W; cd $W || exit 1
ADDR=$(cli address build --payment-verification-key-file $KEY.vkey --testnet-magic "$MAGIC")
read -r IN VAL < <(cli query utxo --address "$ADDR" --output-json --testnet-magic "$MAGIC" | jq -r 'to_entries | sort_by(-.value.value.lovelace)[0] | "\(.key) \(.value.value.lovelace)"')
OUTS=(); TOTAL=0
for a in "$@"; do OUTS+=(--tx-out "$a+$LOV"); TOTAL=$((TOTAL + LOV)); done
FEE=1000000
cli transaction build-raw --fee $FEE --tx-in "$IN" --tx-out "$ADDR+$((VAL - TOTAL - FEE))" "${OUTS[@]}" --out-file fund.raw >/dev/null || exit 1
cli transaction sign --tx-body-file fund.raw --signing-key-file $KEY.skey --out-file fund.signed || exit 1
ID=$(cli transaction txid --tx-file fund.signed | grep -o '[0-9a-f]\{64\}')
cli transaction submit --tx-file fund.signed --testnet-magic "$MAGIC" >/dev/null 2>&1 || { echo "funding transaction refused" >&2; exit 1; }
until cli query utxo --tx-in "$ID#1" --output-json --testnet-magic "$MAGIC" 2>/dev/null | grep -q lovelace; do sleep 0.5; done
echo "funded $# gateways with $LOV lovelace each (transaction $ID)"
