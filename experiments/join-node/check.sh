#!/bin/bash
# Show the joined node's chain tip and its connection log, next to pool 1's tip.
#
#   ./check.sh                      local node: compares with pool 1 on this machine
#   ./check.sh <user@host>          remote node: compares with pool 1 on that host (over SSH)
#   NET=2 ./check.sh <user@host>    ... pool 1 of network 2 there
#   ./check.sh ... 10               show 10 log lines instead of 3
set -uo pipefail

NAME=cardano-joiner
HOST=${1:-}; LINES=${2:-3}
[[ $HOST =~ ^[0-9]+$ ]] && { LINES=$HOST; HOST=""; }

# a local node carries the AS number of the network it joined (AS150 -> net 1, AS200 -> net 2)
ASN=$(docker inspect -f '{{index .Config.Labels "org.seedsecuritylabs.seedemu.meta.asn"}}' "$NAME" 2>/dev/null) \
  || { echo "$NAME is not running"; exit 1; }
[ -n "$ASN" ] && export NET=$(( (ASN - 150) / 50 + 1 ))
source "$(dirname "$0")/../../scripts/lib.sh"

NODE_MAGIC=$(grep -o '"networkMagic": *[0-9]*' "$ROOT/build/joiner/shelley-genesis.json" | grep -o '[0-9]*$')

echo "== $NAME (magic $NODE_MAGIC)"
docker exec "$NAME" cardano-cli query tip --socket-path "$SOCKET" --testnet-magic "$NODE_MAGIC" 2>&1 | tr -d ' \n'; echo
if [ -n "$ASN" ]; then
  echo "== pool 1 of net-$NET"
  tip_of 1
elif [ -n "$HOST" ]; then
  echo "== pool 1 of net-$NET on $HOST"
  ssh "$HOST" "cd ${REMOTE_REPO:-cardano-seed-testnet} && NET=$NET ./scripts/check.sh" | sed -n 2p
fi
echo "== log"
docker logs "$NAME" 2>&1 | grep -a -i "handshake\|mismatch\|refus\|ConnectionManager.*Outbound\|Chain extended" \
  | tail -"$LINES" | cut -c1-240
