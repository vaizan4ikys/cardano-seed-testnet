#!/bin/bash
# Keep the blocks of the chain full, so that measurements run on a chain that carries real data.
# It sends ~15 KB metadata transactions from the key utxo2 and keeps a few of them waiting in the
# mempool, so every block the pools forge is almost full (4 of these transactions fit in the
# 64 KB block limit). Run it on the machine that hosts the network (the other scripts call it
# over ssh); the work itself happens inside pool 1's container (in-container/load-loop.sh).
#
#   ./load.sh dry-run     build and sign a few transactions, print their size, submit NOTHING
#   ./load.sh start       start in the background (inside pool 1's container)
#   ./load.sh status      what it has done so far (the first line is "running" or "not running")
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

LANES=${LANES:-16}
STRINGS=${STRINGS:-230}
FILL_TXS=${FILL_TXS:-5}
MAX_DB_MB=${MAX_DB_MB:-2000}
STALL_SECONDS=${STALL_SECONDS:-120}

CONTAINER=$(require_pool 1)

# run a command inside pool 1's container
in_pool() { docker exec "$CONTAINER" "$@"; }

# success if load-loop.sh is running (it writes its pid to /tmp/load.pid and removes it when it ends)
load_running() { in_pool sh -c 'test -f /tmp/load.pid && kill -0 "$(cat /tmp/load.pid)"' 2>/dev/null; }

case ${1:-} in
  dry-run)
    docker exec -i -e MAGIC="$MAGIC" -e DRY_RUN=1 -e LANES="$LANES" -e STRINGS="$STRINGS" \
      "$CONTAINER" bash -s < "$HERE/in-container/load-loop.sh" ;;
  start)
    if load_running; then
      echo "the load is already running (./load.sh status)"; exit 1
    fi
    docker cp "$HERE/in-container/load-loop.sh" "$CONTAINER:/tmp/load-loop.sh"
    in_pool rm -f /tmp/load.stop /tmp/load.log /tmp/load.count
    docker exec -d -e MAGIC="$MAGIC" -e LANES="$LANES" -e STRINGS="$STRINGS" \
      -e FILL_TXS="$FILL_TXS" -e MAX_DB_MB="$MAX_DB_MB" -e STALL_SECONDS="$STALL_SECONDS" \
      "$CONTAINER" bash /tmp/load-loop.sh
    echo "load started; watch it with ./load.sh status" ;;
  stop)
    in_pool touch /tmp/load.stop                  # load-loop.sh looks for this file and ends
    for _ in $(seq 30); do
      load_running || { echo "load stopped"; exit 0; }
      sleep 1
    done
    echo "still running after 30 s" ;;
  status)
    # other scripts read the first line of this output (running / not running)
    if load_running; then echo "running"; else echo "not running"; fi
    echo "transactions submitted: $(in_pool cat /tmp/load.count 2>/dev/null || echo 0)"
    echo "mempool: $(in_pool cardano-cli conway query tx-mempool info --socket-path "$SOCKET" --testnet-magic "$MAGIC" \
                       | jq -c '{txs: .numberOfTxs, bytes: .sizeInBytes, capacity: .capacityInBytes}')"
    echo "chain database: $(in_pool du -sm /cardano-db | cut -f1) MB, tip: $(tip_of 1 | grep -o '"block":[0-9]*')"
    echo "--- last log lines:"; in_pool tail -5 /tmp/load.log 2>/dev/null || true ;;
  *)
    # no valid command: print the header comment above as usage text
    sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 1 ;;
esac
