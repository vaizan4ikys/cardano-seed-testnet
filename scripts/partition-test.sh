#!/bin/bash
# Partition experiment: cut pool 3 off the network by stopping its SEED router,
# watch the chain fork, restart the router and watch the chain heal.
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
ROUTER=$(pool_router 3)
[ -n "$ROUTER" ] || { echo "router of pool 3 (net-$NET) is not running"; exit 1; }

# one line: time, then "block number + short hash" for each pool
print_tips() {
  printf '%s ' "$(date +%T)"
  for n in 1 2 3; do
    tip=$(docker exec "$(pool_container "$n")" cardano-cli query tip --socket-path "$SOCKET" --testnet-magic "$MAGIC" 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print('blk %s #%s' % (d['block'], d['hash'][:6]))" 2>/dev/null)
    printf '| pool %s %-18s' "$n" "${tip:-n/a}"
  done
  echo
}

echo "== before";                  print_tips
echo "== CUT: stopping $ROUTER";   docker stop "$ROUTER" >/dev/null
for _ in $(seq 1 $((CUT_SECONDS / 10))); do sleep 10; print_tips; done
echo "== HEAL: starting $ROUTER";  docker start "$ROUTER" >/dev/null
for _ in $(seq 1 9); do sleep 10; print_tips; done
