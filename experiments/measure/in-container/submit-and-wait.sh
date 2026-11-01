#!/bin/bash
# Runs INSIDE a joiner's container (started by ../tx-latency.sh).
#
#   submit-and-wait.sh <network magic> <txid> <signed transaction as JSON text>
#
# Submits the transaction through this node, then waits until it is in a block that this node
# has. Prints "<submit time> <seconds>": the clock of this machine when it submitted (seconds
# since 1970) and the seconds until the block (one clock, so no clock skew in that number).
set -e
MAGIC=$1
TXID=$2
export CARDANO_NODE_SOCKET_PATH=/node.socket

echo "$3" > /tmp/tx.signed
START=$(date +%s.%N)
cardano-cli conway transaction submit --tx-file /tmp/tx.signed --testnet-magic "$MAGIC" >/dev/null 2>&1 \
  || { echo "submit failed" >&2; exit 1; }

# in a block once its first output (TXID#0) exists on this node's ledger
until cardano-cli conway query utxo --tx-in "$TXID#0" --testnet-magic "$MAGIC" | grep -q "$TXID"; do
  [ "$SECONDS" -lt 120 ] || { echo "not in a block after 120 s" >&2; exit 1; }
done
awk -v s="$START" -v e="$(date +%s.%N)" 'BEGIN { printf "%.3f %.2f\n", s, e - s }'
