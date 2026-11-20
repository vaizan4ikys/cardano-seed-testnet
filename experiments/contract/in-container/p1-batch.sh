#!/bin/bash
# Runs INSIDE pool 1's container. Sends ONE batch file from the gateway program (experiments/pipeline) through the
# contract as gateway $GATEWAY (A or B; default A) and waits until it is in a block (at most 60 s; before the submit
# it may also wait up to 2 x 20 s for a block, see the loop below). While it waits, it
# sends the same signed transaction again when it is neither in a block nor in the mempool: a block that carried it
# can be replaced by a block of another pool, and then the transaction is gone (wait_tx in p0-lib.sh; the notes about
# it go to stderr). It does NOT wait for one more block on top: the gateway program keeps each batch until it is final.
# sent/<batch hash>.txids lists EVERY transaction built for this batch (written before its submit): if any of them
# is in the chain or in the mempool, the batch counts as sent and nothing new is built (a transaction we gave up on can
# still turn up in a block later; building another one from its change would put the batch on the chain twice). This
# is checked again before every new attempt: a second run of this script for the same batch (after the gateway was
# killed or timed out while the first one still ran in the container) may have sent it meanwhile.
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
mkdir -p sent                                     # sent/<batch hash>.txids: every transaction built for this batch
KUPO=http://127.0.0.1:1442                        # Kupo (indexer) inside this container

# in_chain TXID: does Kupo see an output of this transaction?
in_chain() { curl -s -m 5 "$KUPO/matches/*@$1" | jq -e 'length > 0' >/dev/null 2>&1; }

# already_sent: prints the first transaction built for this batch that is in the chain or in the mempool (if any).
# (sent/<hash>.txid is the one-transaction file of older versions of this script.)
already_sent() {
  local old
  for old in $(cat sent/$BATCH_HASH.txids sent/$BATCH_HASH.txid 2>/dev/null); do
    if in_chain "$old" || in_mempool "$old"; then echo "$old"; return 0; fi
  done
  return 1
}
if OLD_TXID=$(already_sent); then echo "already sent: batch $BATCH_HASH is transaction $OLD_TXID"; exit 0; fi

# A coin the transaction reads or spends can already be spent by a transaction that is not in a block yet. Usually
# that is a registry change of the administrator (every batch READS the registry coin, and the node refuses a
# transaction that reads a coin its mempool has spent), sometimes our own earlier transaction. Then we wait for the
# next block (at most 20 s; before, the gateway could use up its 5 tries in about 25 s and move a good batch to
# dead/) and build again with the coins of then. At most 3 attempts: 2 x 20 s + wait_tx 60 s < the gateway's 120 s.
for attempt in 1 2 3; do
  if [ "$attempt" -gt 1 ] && OLD_TXID=$(already_sent); then
    echo "already sent: batch $BATCH_HASH is transaction $OLD_TXID"; exit 0
  fi
  REG=$(registry_coin)          # the current registry coin (registry.ref is repaired if it is stale)
  [ -n "$REG" ] || { echo "no single registry coin found at the admin address"; exit 1; }
  gw_utxos "$GW" || { echo "cannot read the wallet of gateway $GW"; exit 1; }
  META_FILE=$FILE mk_data_tx "$GW" "b$BATCH_HASH" "$PAY" "$PAYLOV" "$PAYTOK" "$COLL" "$COLLLOV" "$REG" \
    || { echo "could not build the transaction"; exit 1; }
  echo "$TXID" >> sent/$BATCH_HASH.txids        # before the submit, so that a second run sees it at once
  OUT=$(submit_tx "b$BATCH_HASH") && break
  if echo "$OUT" | grep -q 'PlutusFailure'; then
    echo "REFUSED by the contract: gateway $GW is not on the registry list (batch $BATCH_HASH)"; exit 2
  elif echo "$OUT" | grep -q -E 'BadInputsUTxO|All inputs are spent' && [ "$attempt" -lt 3 ]; then
    sleep 1
    if live_coin "$REG"; then   # the registry coin is still in the ledger: something in the mempool spends a coin
      echo "  a coin this transaction needs is spent by a transaction that is not in a block yet (a registry" \
           "change?): waiting for the next block, then building again" >&2
      wait_next_block 20 || true
    fi                          # else the registry changed in a block meanwhile: build again at once
    continue
  else
    echo "submit failed: $(echo "$OUT" | short_err | head -c 200)"; exit 1
  fi
done
SUBMITTED_MS=$(now_ms)
wait_tx "$TXID" "b$BATCH_HASH.signed" 60 || { echo "submitted but not seen in a block yet: $TXID"; exit 1; }
echo "OK: gateway $GW batch $BATCH_HASH is in a block: tx $TXID" \
     "(size $SIZE bytes, fee $FEE lovelace, $(( $(now_ms) - SUBMITTED_MS )) ms after submit)"
