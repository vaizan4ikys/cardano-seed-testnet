#!/bin/bash
# Runs INSIDE pool 1's container (started by ../tx-latency.sh).
#
#   watch-mempool.sh <network magic> <txid>
#
# Prints "<time> mempool" the moment the transaction is first seen in this node's mempool, or
# "<time> block" if it is already in a block when first seen, or "0 timeout" after 120 s.
# <time> is the clock of this machine in seconds since 1970, to the millisecond.
MAGIC=$1
TXID=$2
export CARDANO_NODE_SOCKET_PATH=/node.socket

while [ "$SECONDS" -lt 120 ]; do
  if cardano-cli conway query tx-mempool tx-exists "$TXID" --testnet-magic "$MAGIC" | jq -e .exists >/dev/null; then
    echo "$(date +%s.%N) mempool"; exit 0
  fi
  if cardano-cli conway query utxo --tx-in "$TXID#0" --testnet-magic "$MAGIC" | grep -q "$TXID"; then
    echo "$(date +%s.%N) block"; exit 0
  fi
done
echo "0 timeout"
