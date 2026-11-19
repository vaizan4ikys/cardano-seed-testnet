#!/bin/bash
# Partition experiment: cut pool 3 off the network by stopping its SEED router,
# watch the chain fork, restart the router and watch the chain heal.
# Runs on the machine that hosts the chain; prints one line of chain tips every 10 s.
#
#   ./scripts/partition-test.sh                    cut for 60 s
#   CUT_SECONDS=120 ./scripts/partition-test.sh    cut for 120 s
#   NET=2 ./scripts/partition-test.sh              the same on network 2
#
# Keep CUT_SECONDS short (under about 400): with k=60 the isolated pool must
# forge fewer than 60 blocks, or it cannot roll back after the heal.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

CUT_SECONDS=${CUT_SECONDS:-60}
INTERVAL=10          # seconds between two lines of tips
HEAL_LINES=9         # lines printed after the router is back (9 x 10 s = 90 s)

ROUTER=$(pool_router 3)
[ -n "$ROUTER" ] || { echo "router of pool 3 (net-$NET) is not running"; exit 1; }

# "blk <block number> #<first 6 characters of the block hash>" of pool N (empty if the query fails)
short_tip() {
  docker exec "$(pool_container "$1")" cardano-cli query tip \
      --socket-path "$SOCKET" --testnet-magic "$MAGIC" 2>/dev/null \
    | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('blk %s #%s' % (d['block'], d['hash'][:6]))" 2>/dev/null
}

# one line: time, then the short tip of each pool
print_tips() {
  local n tip
  printf '%s ' "$(date +%T)"
  for n in 1 2 3; do
    tip=$(short_tip "$n")
    printf '| pool %s %-18s' "$n" "${tip:-n/a}"
  done
  echo
}

echo "== before";                  print_tips
echo "== CUT: stopping $ROUTER";   docker stop "$ROUTER" >/dev/null
for _ in $(seq 1 $((CUT_SECONDS / INTERVAL))); do sleep "$INTERVAL"; print_tips; done
echo "== HEAL: starting $ROUTER";  docker start "$ROUTER" >/dev/null
for _ in $(seq 1 "$HEAL_LINES"); do sleep "$INTERVAL"; print_tips; done
