#!/bin/bash
# Send 1000 ADA from utxo1 to utxo2 through pool 1 and check that every pool sees it.
#
#   ./scripts/test-tx.sh          network 1
#   NET=2 ./scripts/test-tx.sh    network 2
#
# utxo1 and utxo2 are the two funded addresses made by gen-testnet.sh.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

POOL1=$(require_pool 1)
KEYS=/cardano/utxo-keys   # inside the container

cli() { docker exec "$POOL1" cardano-cli "$@"; }
query_utxo() { cli conway query utxo --address "$1" --testnet-magic "$MAGIC" --socket-path "$SOCKET" "${@:2}"; }

ADDR1=$(cli conway address build --payment-verification-key-file $KEYS/utxo1/utxo.vkey --testnet-magic "$MAGIC")
ADDR2=$(cli conway address build --payment-verification-key-file $KEYS/utxo2/utxo.vkey --testnet-magic "$MAGIC")
echo "utxo1: $ADDR1"
echo "utxo2: $ADDR2"

echo "--- utxo1 before"
query_utxo "$ADDR1"

# first unspent output (TxHash#TxIx) of utxo1
TXIN=$(query_utxo "$ADDR1" --output-json | python3 -c "import json,sys; print(list(json.load(sys.stdin))[0])")
echo "spending $TXIN, sending 1000 ADA to utxo2"

# build, sign and submit; the files live in /tmp inside the container
cli conway transaction build --tx-in "$TXIN" --tx-out "$ADDR2+1000000000" --change-address "$ADDR1" \
  --testnet-magic "$MAGIC" --socket-path "$SOCKET" --out-file /tmp/tx.raw
cli conway transaction sign --tx-body-file /tmp/tx.raw --signing-key-file $KEYS/utxo1/utxo.skey \
  --testnet-magic "$MAGIC" --out-file /tmp/tx.signed
cli conway transaction submit --tx-file /tmp/tx.signed --testnet-magic "$MAGIC" --socket-path "$SOCKET"
TXID=$(cli conway transaction txid --tx-file /tmp/tx.signed | grep -o '[0-9a-f]\{64\}')

# the transaction is in a block once its first output (TXID#0) exists on the ledger
echo "waiting for $TXID to be included in a block..."
for _ in $(seq 1 60); do
  query_utxo "$ADDR2" | grep -q "$TXID" && break
  sleep 1
done

for n in 1 2 3; do
  echo "--- utxo2 as seen by pool $n"
  docker exec "$(require_pool "$n")" cardano-cli conway query utxo --address "$ADDR2" \
    --testnet-magic "$MAGIC" --socket-path "$SOCKET"
done
