#!/bin/bash
# Keep the blocks of the chain full, so that measurements run on a chain that carries real data.
# It sends ~15 KB metadata transactions from the key utxo2 and keeps a few of them waiting in the
# mempool, so every block the pools forge is almost full (4 of these transactions fit in the
# 64 KB block limit). Run it on the machine that hosts the network.
#
#   ./load.sh dry-run     build and sign a few transactions, print their size, submit NOTHING
#   ./load.sh start       start in the background (inside pool 1's container)
#   ./load.sh status      what it has done so far
#   ./load.sh stop
#   NET=2 ./load.sh ...   network 2
#
# Settings (environment): LANES (16)      UTxOs it spends in parallel, one tx per UTxO per block
#                         STRINGS (230)   64-byte metadata strings per tx; 230 gives ~15 KB
#                         FILL_TXS (5)    keeps this many txs waiting in the mempool (it holds ~8)
#                         MAX_DB_MB (2000) stops when the chain database is this big
#                         STALL_SECONDS (120) pauses while no new block comes for this long
#
# The load uses utxo2. send-metadata.sh and the measurements spend utxo1, so they do not
# collide with it.
set -euo pipefail
source "$(dirname "$0")/../../scripts/lib.sh"
HERE=$(cd "$(dirname "$0")" && pwd)

POOL=$(require_pool 1)
in_pool() { docker exec "$POOL" "$@"; }

case ${1:-} in
  dry-run)
    docker exec -i -e MAGIC="$MAGIC" -e DRY_RUN=1 -e LANES="${LANES:-16}" -e STRINGS="${STRINGS:-230}" \
      "$POOL" bash -s < "$HERE/in-container/load-loop.sh" ;;
  start)
    if in_pool sh -c 'test -f /tmp/load.pid && kill -0 "$(cat /tmp/load.pid)"' 2>/dev/null; then
      echo "the load is already running (./load.sh status)"; exit 1
    fi
    docker cp "$HERE/in-container/load-loop.sh" "$POOL:/tmp/load-loop.sh"
    in_pool rm -f /tmp/load.stop /tmp/load.log /tmp/load.count
    docker exec -d -e MAGIC="$MAGIC" -e LANES="${LANES:-16}" -e STRINGS="${STRINGS:-230}" \
      -e FILL_TXS="${FILL_TXS:-5}" -e MAX_DB_MB="${MAX_DB_MB:-2000}" -e STALL_SECONDS="${STALL_SECONDS:-120}" \
      "$POOL" bash /tmp/load-loop.sh
    echo "load started; watch it with ./load.sh status" ;;
  stop)
    in_pool touch /tmp/load.stop
    for _ in $(seq 30); do
      in_pool sh -c 'test -f /tmp/load.pid && kill -0 "$(cat /tmp/load.pid)"' 2>/dev/null || { echo "load stopped"; exit 0; }
      sleep 1
    done
    echo "still running after 30 s" ;;
  status)
    if in_pool sh -c 'test -f /tmp/load.pid && kill -0 "$(cat /tmp/load.pid)"' 2>/dev/null; then echo "running"; else echo "not running"; fi
    echo "transactions submitted: $(in_pool cat /tmp/load.count 2>/dev/null || echo 0)"
    echo "mempool: $(in_pool cardano-cli conway query tx-mempool info --socket-path "$SOCKET" --testnet-magic "$MAGIC" | jq -c '{txs: .numberOfTxs, bytes: .sizeInBytes, capacity: .capacityInBytes}')"
    echo "chain database: $(in_pool du -sm /cardano-db | cut -f1) MB, tip: $(tip_of 1 | grep -o '"block":[0-9]*')"
    echo "--- last log lines:"; in_pool tail -5 /tmp/load.log 2>/dev/null || true ;;
  *)
    sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 1 ;;
esac
