#!/bin/bash
# Time one sync from an empty database: how long a fresh joiner needs to catch up with the chain.
# Run it on the joining machine, after ../join-node/fetch-chain-files.sh.
#
#   ./sync-time.sh <peer-ip> [port]
#   DELAY=100 LOSS=1 ./sync-time.sh <peer-ip>     with added delay (ms) and packet loss (%)
#   LISTEN=1 ./sync-time.sh <peer-ip>             also let further nodes join through this one
#   DOWN=20 UP=5 TIMEOUT=3600 ./sync-time.sh ...  bandwidth caps in Mbit/s (netem.sh); give-up time in s (default 900)
#
# Prints one line:  <seconds> <blocks> <ready seconds> <database kB> <MB received from the network>
# <seconds> runs from "docker run" until the node's tip is at most 20 slots (20 s) older than the
# clock of the chain (a few blocks behind the pools). <ready seconds> is the part until the node answers at all: its start-up, which
# takes most of the time on a short chain. The difference is the sync itself.
# <database kB> is the size of the joiner's chain database at the end (what was copied).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PEER=${1:?usage: $0 <peer-ip> [port]}
PORT=${2:-3001}
GENESIS=$HERE/../../build/joiner/shelley-genesis.json
MAGIC=$(grep -o '"networkMagic": *[0-9]*' "$GENESIS" | grep -o '[0-9]*$')
CHAIN_START=$(date -u -d "$(grep -o '"systemStart": *"[^"]*"' "$GENESIS" | cut -d'"' -f4)" +%s)   # slot 0 (1 s slots)

NAME=${NAME:-cardano-joiner}; export NAME      # NAME=hop4 HOST_PORT=3002 ./sync-time.sh ... for an extra node
START=$(date +%s.%N)
READY=
"$HERE/../join-node/join.sh" remote "$PEER" "$PORT" >/dev/null
"$HERE/netem.sh" set "${DELAY:-0}" "${LOSS:-0}" "${DOWN:-0}" "${UP:-0}"   # also with 0/0, so that every run has the same qdisc

while true; do
  TIP=$(docker exec "$NAME" cardano-cli query tip --socket-path /node.socket \
          --testnet-magic "$MAGIC" 2>/dev/null || true)
  [ -z "$READY" ] && [ -n "$TIP" ] && READY=$(date +%s.%N)
  SLOT=$(grep -o '"slot": *[0-9]*' <<< "$TIP" | grep -o '[0-9]*$' || true)
  if [ -n "$SLOT" ] && [ $(( $(date +%s) - CHAIN_START - SLOT )) -le 20 ]; then break; fi
  [ "$(awk -v s="$START" -v n="$(date +%s.%N)" 'BEGIN { print (n - s > '"${TIMEOUT:-900}"') }')" = 0 ] \
    || { echo "not synced after ${TIMEOUT:-900} s" >&2; exit 1; }
  sleep 0.2
done

END=$(date +%s.%N)
BLOCKS=$(grep -o '"block": *[0-9]*' <<< "$TIP" | grep -o '[0-9]*$')
DB_KB=$(docker exec "$NAME" du -sk /db | cut -f1)
RX_MB=$(docker exec "$NAME" cat /proc/net/dev | awk -F'[: ]+' '$2 == "eth0" { printf "%.0f", $3 / 1048576 }')
awk -v s="$START" -v e="$END" -v r="$READY" -v b="$BLOCKS" -v k="$DB_KB" -v x="$RX_MB" 'BEGIN { printf "%.1f %d %.1f %d %s\n", e - s, b, r - s, k, x }'
