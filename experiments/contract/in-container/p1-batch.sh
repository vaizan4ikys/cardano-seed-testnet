#!/bin/bash
# Runs INSIDE pool 1's container. Sends ONE batch file from the gateway program (experiments/pipeline) through the
# contract as gateway $GATEWAY (A or B; default A) and waits until it is in a block. While it waits, it sends the
# same signed transaction again every 10 s (up to 90 s): a block that carried it can be replaced by a block of
# another pool, and then the transaction is gone (wait_tx in p0-lib.sh; the notes about it go to stderr). It does NOT
# wait for one more block on top: the gateway program keeps each batch until it is final.
# The current registry coin is registry_coin (p0-lib.sh): registry.ref, or the coin found by its token.
#   GATEWAY=A P0_DIR=/tmp/p0n ./p1-batch.sh <magic> <batch.json>
# Exit codes (the gateway program reads them): 0 = the batch is in a block (or was already sent: idempotent by hash),
# 2 = REFUSED for good by the contract (the gateway is not on the list), 1 = anything else (the gateway retries later).
# The last line printed on stdout is one readable sentence: "OK: gateway G batch HASH is in a block: tx TXID (...)",
# "already sent: batch HASH is transaction TXID", or the reason of the failure.
set -u
MAGIC=$1; FILE=$2; GW=${GATEWAY:-A}
. /tmp/p0-scripts/p0-lib.sh                       # sets W (= $P0_DIR), cli, mk_data_tx, submit_tx, wait_tx ...
BATCH_HASH=$(sha256sum "$FILE" | cut -d' ' -f1)
mkdir -p sent                                     # sent/<batch hash>.txid remembers which batch became which transaction
KUPO=http://127.0.0.1:1442                        # Kupo (indexer) inside this container

# in_chain TXID: does Kupo see an output of this transaction?
in_chain() { curl -s -m 5 "$KUPO/matches/*@$1" | jq -e 'length > 0' >/dev/null 2>&1; }

# already sent? (same batch hash, same transaction): do nothing twice
if [ -f sent/$BATCH_HASH.txid ]; then
  OLD_TXID=$(cat sent/$BATCH_HASH.txid)
  if in_chain "$OLD_TXID" \
     || cli query tx-mempool tx-exists "$OLD_TXID" --testnet-magic "$MAGIC" 2>/dev/null | grep -q true; then
    echo "already sent: batch $BATCH_HASH is transaction $OLD_TXID"; exit 0
  fi
fi

for attempt in 1 2; do
  REG=$(registry_coin)          # the current registry coin (registry.ref is repaired if it is stale)
  [ -n "$REG" ] || { echo "no single registry coin found at the admin address"; exit 1; }
  gw_utxos "$GW" || { echo "cannot read the wallet of gateway $GW"; exit 1; }
  META_FILE=$FILE mk_data_tx "$GW" "b$BATCH_HASH" "$PAY" "$PAYLOV" "$PAYTOK" "$COLL" "$COLLLOV" "$REG" \
    || { echo "could not build the transaction"; exit 1; }
  OUT=$(submit_tx "b$BATCH_HASH") && break
  if echo "$OUT" | grep -q 'PlutusFailure'; then
    echo "REFUSED by the contract: gateway $GW is not on the registry list (batch $BATCH_HASH)"; exit 2
  elif echo "$OUT" | grep -q 'BadInputsUTxO' && [ "$attempt" = 1 ]; then
    sleep 1; continue          # the registry (or our own coin) changed while we built: look again once
  else
    echo "submit failed: $(echo "$OUT" | short_err | head -c 200)"; exit 1
  fi
done
echo "$TXID" > sent/$BATCH_HASH.txid
SUBMITTED_MS=$(now_ms)
wait_tx "$TXID" "b$BATCH_HASH.signed" || { echo "submitted but not seen in a block yet: $TXID"; exit 1; }
echo "OK: gateway $GW batch $BATCH_HASH is in a block: tx $TXID" \
     "(size $SIZE bytes, fee $FEE lovelace, $(( $(now_ms) - SUBMITTED_MS )) ms after submit)"
