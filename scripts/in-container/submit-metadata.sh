#!/bin/bash
# Runs INSIDE pool 1's container (started by ../send-metadata.sh).
# Builds, signs and submits a transaction that carries the metadata, then waits
# until it is in a block.
#
#   submit-metadata.sh <network magic> <metadata json>
#
# utxo1 pays the fee; everything else goes back to utxo1 as change.
set -e
MAGIC=$1
META=$2
KEY=/cardano/utxo-keys/utxo1/utxo
export CARDANO_NODE_SOCKET_PATH=/node.socket

ADDR=$(cardano-cli conway address build --payment-verification-key-file $KEY.vkey --testnet-magic "$MAGIC")

# spend all unspent outputs (TxHash#TxIx) of utxo1
INPUTS=()
for txin in $(cardano-cli conway query utxo --address "$ADDR" --testnet-magic "$MAGIC" | grep -o '[0-9a-f]\{64\}#[0-9]*'); do
  INPUTS+=(--tx-in "$txin")
done
[ ${#INPUTS[@]} -gt 0 ] || { echo "utxo1 has no funds"; exit 1; }

cd /tmp
echo "$META" > meta.json
cardano-cli conway transaction build --testnet-magic "$MAGIC" "${INPUTS[@]}" \
  --change-address "$ADDR" --metadata-json-file meta.json --out-file tx.raw
cardano-cli conway transaction sign --tx-body-file tx.raw --signing-key-file $KEY.skey --out-file tx.signed
TXID=$(cardano-cli conway transaction txid --tx-file tx.signed | grep -o '[0-9a-f]\{64\}')

START=$(date +%s.%N)
cardano-cli conway transaction submit --tx-file tx.signed --testnet-magic "$MAGIC"
echo "txid: $TXID"

# the transaction is in a block once its first output (TXID#0) exists on the ledger
for _ in $(seq 1 240); do
  if cardano-cli conway query utxo --tx-in "$TXID#0" --testnet-magic "$MAGIC" | grep -q "$TXID"; then
    SECONDS_TAKEN=$(awk -v a="$START" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}')
    echo "in a block after $SECONDS_TAKEN s"
    exit 0
  fi
  sleep 0.5
done
echo "not in a block after 120 s: check that the pools are producing blocks"
exit 1
