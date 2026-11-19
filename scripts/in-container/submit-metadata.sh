#!/bin/bash
# Runs INSIDE pool 1's container (started by ../send-metadata.sh and by experiments/measure/tx-latency.sh,
# which pipe it into "bash -s"; so it cannot source other repo files).
# Builds, signs and submits a transaction that carries the metadata, then waits
# until it is in a block.
#
#   submit-metadata.sh <network magic> <metadata json>
#   BUILD_ONLY=1 submit-metadata.sh ...    do not submit: print "txid: <id>" and the signed transaction
#
# utxo1 pays the fee; everything else goes back to utxo1 as change.
# Prints "txid: <id>" and then "in a block after <s> s" (exit 0), or an error (exit 1).
set -e

MAGIC=$1
META=$2
KEY=/cardano/utxo-keys/utxo1/utxo     # utxo.vkey / utxo.skey of the first funded address
export CARDANO_NODE_SOCKET_PATH=/node.socket

POLL_STEP=0.5                         # seconds between two checks for the transaction
POLL_TRIES=240                        # 240 x 0.5 s = 120 s

ADDR=$(cardano-cli conway address build --payment-verification-key-file "$KEY.vkey" --testnet-magic "$MAGIC")

# spend all unspent outputs (TxHash#TxIx) of utxo1
# ("|| true": grep finds nothing when utxo1 is empty, and then the message below must be shown, not a silent exit)
TXINS=$(cardano-cli conway query utxo --address "$ADDR" --testnet-magic "$MAGIC" \
          | grep -o '[0-9a-f]\{64\}#[0-9]*' || true)
INPUTS=()
for txin in $TXINS; do
  INPUTS+=(--tx-in "$txin")
done
[ ${#INPUTS[@]} -gt 0 ] || { echo "utxo1 has no funds"; exit 1; }

# build, sign and take the transaction id (the files stay in /tmp of the container)
cd /tmp
echo "$META" > meta.json
cardano-cli conway transaction build --testnet-magic "$MAGIC" "${INPUTS[@]}" \
  --change-address "$ADDR" --metadata-json-file meta.json --out-file tx.raw
cardano-cli conway transaction sign --tx-body-file tx.raw --signing-key-file "$KEY.skey" --out-file tx.signed
TXID=$(cardano-cli conway transaction txid --tx-file tx.signed | grep -o '[0-9a-f]\{64\}')

# BUILD_ONLY=1: print the signed transaction instead of submitting it, so that another node can
# submit it (experiments/measure/tx-latency.sh)
if [ "${BUILD_ONLY:-}" = 1 ]; then
  echo "txid: $TXID"
  cat tx.signed
  exit 0
fi

START=$(date +%s.%N)
cardano-cli conway transaction submit --tx-file tx.signed --testnet-magic "$MAGIC"
echo "txid: $TXID"

# the transaction is in a block once its first output (TXID#0) exists on the ledger
for _ in $(seq 1 $POLL_TRIES); do
  if cardano-cli conway query utxo --tx-in "$TXID#0" --testnet-magic "$MAGIC" | grep -q "$TXID"; then
    SECONDS_TAKEN=$(awk -v a="$START" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}')
    echo "in a block after $SECONDS_TAKEN s"
    exit 0
  fi
  sleep $POLL_STEP
done
echo "not in a block after 120 s: check that the pools are producing blocks"
exit 1
