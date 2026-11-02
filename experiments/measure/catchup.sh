#!/bin/bash
# Run ON a machine that hosts a synced node (see sync-time.sh): cut the node off for <outage seconds>,
# reconnect it, and time how long it needs to catch up with the chain again.
#
#   ./catchup.sh 300                  cut off for 5 minutes (NAME=hop1 ./catchup.sh 300 for a named node)
#
# The cut-off drops every packet the node sends (tc netem loss 100%, see netem.sh), so it can neither
# ask for blocks nor answer. Prints one line:  <outage s> <slots behind at reconnect> <catch-up seconds> <MB received>
# "caught up" is the same test as in sync-time.sh: the node's tip is at most 20 slots (20 s) behind the chain clock.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUTAGE=${1:?usage: $0 <outage seconds>}
NAME=${NAME:-cardano-joiner}; export NAME
GENESIS=$HERE/../../build/joiner/shelley-genesis.json
MAGIC=$(grep -o '"networkMagic": *[0-9]*' "$GENESIS" | grep -o '[0-9]*$')
CHAIN_START=$(date -u -d "$(grep -o '"systemStart": *"[^"]*"' "$GENESIS" | cut -d'"' -f4)" +%s)
behind() {   # slots between the chain clock and the node's tip (empty if the node does not answer)
  local slot
  slot=$(docker exec "$NAME" cardano-cli query tip --socket-path /node.socket --testnet-magic "$MAGIC" 2>/dev/null | grep -o '"slot": *[0-9]*' | grep -o '[0-9]*$') || true
  [ -n "$slot" ] && echo $(( $(date +%s) - CHAIN_START - slot ))
}
rx_mb() { docker exec "$NAME" cat /proc/net/dev | awk -F'[: ]+' '$2 == "eth0" { printf "%.1f", $3 / 1048576 }'; }

"$HERE/netem.sh" set 0 100
sleep "$OUTAGE"
BEHIND=$(behind)
RX0=$(rx_mb)
"$HERE/netem.sh" set 0 0
START=$(date +%s.%N)
[ -n "${TRACE:-}" ] && echo "seconds_after_reconnect,received_bytes" > "$TRACE"
rx_bytes() { docker exec "$NAME" cat /proc/net/dev | awk -F'[: ]+' '$2 == "eth0" { print $3 }'; }
until [ -n "$(behind)" ] && [ "$(behind)" -le 20 ]; do
  [ "$(awk -v s="$START" -v n="$(date +%s.%N)" 'BEGIN { print (n - s > '"${TIMEOUT:-1800}"') }')" = 0 ] || { echo "$OUTAGE $BEHIND NA NA"; exit 0; }
  [ -n "${TRACE:-}" ] && echo "$(awk -v s="$START" -v n="$(date +%s.%N)" 'BEGIN { printf "%.1f", n - s }'),$(rx_bytes)" >> "$TRACE"
  sleep 0.5
done
awk -v o="$OUTAGE" -v b="$BEHIND" -v s="$START" -v e="$(date +%s.%N)" -v r0="$RX0" -v r1="$(rx_mb)" 'BEGIN { printf "%d %d %.1f %.1f\n", o, b, e - s, r1 - r0 }'
