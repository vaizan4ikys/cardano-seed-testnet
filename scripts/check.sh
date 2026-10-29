#!/bin/bash
# Show the chain tip seen by every pool of the network.
#
#   ./scripts/check.sh          network 1
#   NET=2 ./scripts/check.sh    network 2
#
# All pools should report the same block hash (give or take the newest block).
set -uo pipefail
source "$(dirname "$0")/lib.sh"

for n in 1 2 3; do
  echo "== pool $n: $(pool_container "$n")"
  tip_of "$n" | grep -oE '"(block|slot|epoch|era|syncProgress)":"?[A-Za-z0-9.]*"?|rror.*' | tr '\n' ' '
  echo
done
