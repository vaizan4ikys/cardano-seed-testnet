#!/bin/bash
# Runs INSIDE pool 1's container. One transaction from the funded genesis key utxo1 that pays every site gateway TWO coins:
# a payment coin (LOVELACE, default 100 ADA) and a collateral coin (10 ADA). Waits until it is in a block.
#   ms-fund.sh <magic> <address> [<address> ...]
set -u
export CARDANO_NODE_SOCKET_PATH=/node.socket
cli() { cardano-cli conway "$@"; }
MAGIC=$1; shift
LOV=${LOVELACE:-100000000}; COL=10000000
KEY=/cardano/utxo-keys/utxo1/utxo
W=/tmp/ms-fund; rm -rf $W; mkdir -p $W; cd $W || exit 1
ADDR=$(cli address build --payment-verification-key-file $KEY.vkey --testnet-magic "$MAGIC")
read -r IN VAL < <(cli query utxo --address "$ADDR" --output-json --testnet-magic "$MAGIC" | jq -r 'to_entries | sort_by(-.value.value.lovelace)[0] | "\(.key) \(.value.value.lovelace)"')
OUTS=(); TOTAL=0
for a in "$@"; do OUTS+=(--tx-out "$a+$LOV" --tx-out "$a+$COL"); TOTAL=$((TOTAL + LOV + COL)); done
FEE=1000000
cli transaction build-raw --fee $FEE --tx-in "$IN" --tx-out "$ADDR+$((VAL - TOTAL - FEE))" "${OUTS[@]}" --out-file fund.raw >/dev/null || exit 1
cli transaction sign --tx-body-file fund.raw --signing-key-file $KEY.skey --out-file fund.signed || exit 1
ID=$(cli transaction txid --tx-file fund.signed | grep -o '[0-9a-f]\{64\}')
cli transaction submit --tx-file fund.signed --testnet-magic "$MAGIC" >/dev/null 2>&1 || { echo "funding transaction refused" >&2; exit 1; }
until cli query utxo --tx-in "$ID#0" --output-json --testnet-magic "$MAGIC" 2>/dev/null | grep -q lovelace; do sleep 0.5; done
echo "funded $# site gateways: $LOV + $COL lovelace each (transaction $ID)"
