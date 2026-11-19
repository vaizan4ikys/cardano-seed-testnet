#!/bin/bash
# Show the chain tip seen by every pool of the network. Runs on the machine that hosts the chain.
#
#   ./scripts/check.sh          network 1
#   NET=2 ./scripts/check.sh    network 2
#
# All pools should report the same block hash (give or take the newest block).
set -uo pipefail
source "$(dirname "$0")/lib.sh"

# the fields of the tip that are worth reading (the rest of the JSON is dropped), or an error message
TIP_FIELDS='"(block|slot|epoch|era|syncProgress)":"?[A-Za-z0-9.]*"?|rror.*'

for pool in 1 2 3; do
  echo "== pool $pool: $(pool_container "$pool")"
  tip_of "$pool" | grep -oE "$TIP_FIELDS" | tr '\n' ' '
  echo
done
