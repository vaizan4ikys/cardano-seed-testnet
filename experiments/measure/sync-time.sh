#!/bin/bash
# Time one sync from an empty database: how long does a fresh joiner need to catch up with the chain?
# Runs ON the joining machine (a VM), after ../join-node/fetch-chain-files.sh. The drivers in this folder
# (run-all.sh, hops.sh, ...) start it over ssh.
#
# Usage:
#   ./sync-time.sh <peer-ip> [port]            port defaults to 3001
#
# Environment (default):
#   DELAY    delay in ms added to what the node sends                (0)
#   LOSS     packet loss in %                                        (0)
#   DOWN     download cap in Mbit/s, 0 = no cap (see netem.sh)       (0)
#   UP       upload cap in Mbit/s, 0 = no cap                        (0)
#   TIMEOUT  seconds until the sync counts as failed (exit 1)        (900)
#   LISTEN   1 = also publish the node's port, so that further nodes can join through it (see join.sh)
#   NAME     container name, for an extra node on the machine, e.g. NAME=hop4 HOST_PORT=3002   (cardano-joiner)
#
# Prints one line:  <seconds> <blocks> <ready seconds> <database kB> <MB received from the network>
#   <seconds>        from "docker run" until the node's tip is at most 20 slots (20 s) older than the clock of
#                    the chain, i.e. a few blocks behind the pools
#   <ready seconds>  the part until the node answers at all (its start-up); it takes most of the time on a short
#                    chain. The difference to <seconds> is the sync itself.
#   <database kB>    size of the joiner's chain database at the end (what was copied)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PEER=${1:?usage: $0 <peer-ip> [port]}
PORT=${2:-3001}
NAME=${NAME:-cardano-joiner}; export NAME      # join.sh and netem.sh read it
TIMEOUT=${TIMEOUT:-900}
MAX_BEHIND=20                                  # "synced" = the tip is at most this many slots (seconds) old

GENESIS=$HERE/../../build/joiner/shelley-genesis.json
MAGIC=$(grep -o '"networkMagic": *[0-9]*' "$GENESIS" | grep -o '[0-9]*$')
SYSTEM_START=$(grep -o '"systemStart": *"[^"]*"' "$GENESIS" | cut -d'"' -f4)
CHAIN_START=$(date -u -d "$SYSTEM_START" +%s)  # slot 0 of the chain (1 s slots)

# true when more than $TIMEOUT seconds have passed since $START
timed_out() {
  [ "$(awk -v s="$START" -v n="$(date +%s.%N)" -v t="$TIMEOUT" 'BEGIN { print (n - s > t) }')" = 1 ]
}

START=$(date +%s.%N)
READY=
"$HERE/../join-node/join.sh" remote "$PEER" "$PORT" >/dev/null
# netem.sh also runs with 0/0, so that every run has the same qdisc
"$HERE/netem.sh" set "${DELAY:-0}" "${LOSS:-0}" "${DOWN:-0}" "${UP:-0}"

while true; do
  TIP=$(docker exec "$NAME" cardano-cli query tip --socket-path /node.socket \
          --testnet-magic "$MAGIC" 2>/dev/null || true)
  [ -z "$READY" ] && [ -n "$TIP" ] && READY=$(date +%s.%N)
  SLOT=$(grep -o '"slot": *[0-9]*' <<< "$TIP" | grep -o '[0-9]*$' || true)
  if [ -n "$SLOT" ] && [ $(( $(date +%s) - CHAIN_START - SLOT )) -le "$MAX_BEHIND" ]; then break; fi
  timed_out && { echo "not synced after $TIMEOUT s" >&2; exit 1; }
  sleep 0.2
done

END=$(date +%s.%N)
BLOCKS=$(grep -o '"block": *[0-9]*' <<< "$TIP" | grep -o '[0-9]*$')
DB_KB=$(docker exec "$NAME" du -sk /db | cut -f1)
RX_MB=$(docker exec "$NAME" cat /proc/net/dev | awk -F'[: ]+' '$2 == "eth0" { printf "%.0f", $3 / 1048576 }')
awk -v s="$START" -v e="$END" -v r="$READY" -v b="$BLOCKS" -v k="$DB_KB" -v x="$RX_MB" \
  'BEGIN { printf "%.1f %d %.1f %d %s\n", e - s, b, r - s, k, x }'
