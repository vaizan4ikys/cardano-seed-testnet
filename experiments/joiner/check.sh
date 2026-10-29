#!/bin/bash
# Compare the joiner's chain tip with pool 1 of the network it joined, and show
# the last lines of its log.
#
#   ./check.sh        4 log lines
#   ./check.sh 10     10 log lines
set -uo pipefail

NAME=cardano-joiner
FIRST_AS=$(docker inspect -f '{{index .Config.Labels "org.seedsecuritylabs.seedemu.meta.asn"}}' "$NAME" 2>/dev/null) \
  || { echo "$NAME is not running"; exit 1; }
export NET=$(( (FIRST_AS - 150) / 50 + 1 ))   # AS150 -> net 1, AS200 -> net 2
source "$(dirname "$0")/../../scripts/lib.sh"

echo "== pool 1 of net-$NET ($(pool_container 1)), magic $MAGIC"
tip_of 1
echo "== $NAME"
docker exec "$NAME" cardano-cli query tip --socket-path "$SOCKET" --testnet-magic "$MAGIC" 2>&1 | tr -d ' \n'; echo
echo "== log: connection and chain lines"
docker logs "$NAME" 2>&1 | grep -a -i "handshake\|mismatch\|refus\|magic\|ConnectionManager.*Outbound\|Chain extended" \
  | tail -"${1:-4}" | cut -c1-260
