#!/bin/bash
# Runs INSIDE pool 1's container. Sends ONE batch file from the gateway program (experiments/pipeline) through the
# contract as gateway $GATEWAY (A or B; default A) and waits until it is in a block.
#   GATEWAY=A P0_DIR=/tmp/p0n ./p1-batch.sh <magic> <batch.json>
# Exit codes (the gateway program reads them): 0 = the batch is in a block (or was already sent: idempotent by hash),
# 2 = REFUSED for good by the contract (the gateway is not on the list), 1 = anything else (the gateway retries later).
# The last line printed is one readable sentence.
set -u
MAGIC=$1; FILE=$2; G=${GATEWAY:-A}
. /tmp/p0-scripts/p0-lib.sh                       # sets W (= $P0_DIR), cli, mk_data_tx, submit_tx, wait_tx ...
H=$(sha256sum "$FILE" | cut -d' ' -f1)
mkdir -p sent
KUPO=http://127.0.0.1:1442

in_chain() { curl -s -m 5 "$KUPO/matches/*@$1" | jq -e 'length > 0' >/dev/null 2>&1; }

# already sent? (same batch hash, same transaction): do nothing twice
if [ -f sent/$H.txid ]; then
  T=$(cat sent/$H.txid)
  if in_chain "$T" || cli query tx-mempool tx-exists "$T" --testnet-magic "$MAGIC" 2>/dev/null | grep -q true; then
    echo "already sent: batch $H is transaction $T"; exit 0
  fi
fi

# the current registry coin: the one coin at the admin address that carries the registry token
find_registry() {
  cli query utxo --address "$(cat admin.addr)" --output-json --testnet-magic "$MAGIC" \
    | jq -r --arg p "$(cat policy.id)" --arg t "$(cat token.hex)" \
        '[to_entries[] | select(.value.value[$p][$t] == 1) | .key] | if length == 1 then .[0] else empty end'
}

for attempt in 1 2; do
  REG=$(find_registry)
  [ -n "$REG" ] || { echo "no single registry coin found at the admin address"; exit 1; }
  gw_utxos "$G" || { echo "cannot read the wallet of gateway $G"; exit 1; }
  META_FILE=$FILE mk_data_tx "$G" "b$H" "$PAY" "$PAYLOV" "$PAYTOK" "$COLL" "$COLLLOV" "$REG" \
    || { echo "could not build the transaction"; exit 1; }
  OUT=$(submit_tx "b$H") && break
  if echo "$OUT" | grep -q 'PlutusFailure'; then
    echo "REFUSED by the contract: gateway $G is not on the registry list (batch $H)"; exit 2
  elif echo "$OUT" | grep -q 'BadInputsUTxO' && [ "$attempt" = 1 ]; then
    sleep 1; continue                              # the registry (or our own coin) changed while we built: look again once
  else
    echo "submit failed: $(echo "$OUT" | short_err | head -c 200)"; exit 1
  fi
done
echo "$TXID" > sent/$H.txid
T0=$(now_ms)
wait_tx "$TXID" || { echo "submitted but not seen in a block yet: $TXID"; exit 1; }
echo "OK: gateway $G batch $H is in a block: tx $TXID (size $SIZE bytes, fee $FEE lovelace, $(( $(now_ms) - T0 )) ms after submit)"
