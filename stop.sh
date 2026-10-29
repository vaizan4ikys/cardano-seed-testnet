#!/bin/bash
# Stop and remove the containers and networks of one testnet.
#
#   ./stop.sh          network 1
#   NET=2 ./stop.sh    network 2
#
# (A plain "docker compose down" inside build/net-<N>/output finds nothing,
# because the compose project is named cardano-net-<N>, not "output".)
set -euo pipefail
source "$(dirname "$0")/scripts/lib.sh"

if [ -d "$OUTPUT" ]; then
  (cd "$OUTPUT" && docker compose -p "$PROJECT" down 2>/dev/null) || true
fi
expose_rule del
echo "net-$NET stopped"
