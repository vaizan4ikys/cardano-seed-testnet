#!/bin/bash
# Runs INSIDE pool 1's container (demo.sh / fresh.sh copy it to /tmp/p0-scripts/). Shows who is on the registry list.
#   P0_DIR=/tmp/p0n ./p1-list.sh <magic>
# Last line is machine readable (demo.sh greps it):  REGISTRY size=N A=enrolled|not-enrolled B=enrolled|not-enrolled
set -eu
export CARDANO_NODE_SOCKET_PATH=/node.socket
MAGIC=${1:?usage: p1-list.sh <magic>}
cd "${P0_DIR:-/tmp/p0}"
cli() { cardano-cli conway "$@"; }

# the registry coin holds the list of enrolled key hashes as its inline datum
REG=$(cat registry.ref)
COIN=$(cli query utxo --tx-in "$REG" --output-json --testnet-magic "$MAGIC")
echo "$COIN" | grep -q lovelace \
  || { echo "registry coin $REG not found (spent?): run p1-enroll.sh to repair registry.ref"; exit 1; }
LIST=$(echo "$COIN" | jq -c '[.[].inlineDatum.list[].bytes]')
SIZE=$(echo "$LIST" | jq length)
echo "registry coin ${REG%#*}#${REG#*#}   list size $SIZE"

# is the key hash of gateway A / B on the list?
STATES=""
for g in A B; do
  key_hash=$(cat gw$g.pkh)
  if [ "$(echo "$LIST" | jq -r --arg k "$key_hash" 'index($k) != null')" = true ]; then
    state=enrolled
  else
    state=not-enrolled
  fi
  echo "  gateway $g: $state   key hash ${key_hash:0:8}...${key_hash: -6}"
  STATES="$STATES $g=$state"
done
echo "REGISTRY size=$SIZE$STATES"
