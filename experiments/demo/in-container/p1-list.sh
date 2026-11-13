#!/bin/bash
# Runs INSIDE pool 1's container (demo.sh / fresh.sh copy it to /tmp/p0-scripts/). Shows who is on the registry list.
#   P0_DIR=/tmp/p0n ./p1-list.sh <magic>
# Last line is machine readable:  REGISTRY size=N A=enrolled|not-enrolled B=enrolled|not-enrolled
set -eu
export CARDANO_NODE_SOCKET_PATH=/node.socket
MAGIC=${1:?usage: p1-list.sh <magic>}
cd "${P0_DIR:-/tmp/p0}"
cli() { cardano-cli conway "$@"; }
REG=$(cat registry.ref)
U=$(cli query utxo --tx-in "$REG" --output-json --testnet-magic "$MAGIC")
echo "$U" | grep -q lovelace || { echo "registry coin $REG not found (spent?): run p1-enroll.sh to repair registry.ref"; exit 1; }
LIST=$(echo "$U" | jq -c '[.[].inlineDatum.list[].bytes]')
N=$(echo "$LIST" | jq length)
echo "registry coin ${REG%#*}#${REG#*#}   list size $N"
ST=""
for g in A B; do
  k=$(cat gw$g.pkh)
  if [ "$(echo "$LIST" | jq -r --arg k "$k" 'index($k) != null')" = true ]; then s=enrolled; else s=not-enrolled; fi
  echo "  gateway $g: $s   key hash ${k:0:8}...${k: -6}"
  ST="$ST $g=$s"
done
echo "REGISTRY size=$N$ST"
