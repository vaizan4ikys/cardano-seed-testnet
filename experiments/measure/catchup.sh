#!/bin/bash
# Cut a synced node off the network for <outage seconds>, reconnect it, and time how long it needs to
# catch up with the chain again. Runs ON a machine that hosts a synced node (see sync-time.sh); outage.sh
# starts it over ssh.
#
# Usage:
#   ./catchup.sh <outage seconds>            e.g. ./catchup.sh 300 = cut off for 5 minutes
#
# Environment (default):
#   NAME     container of the node, e.g. NAME=hop1 for a named node   (cardano-joiner)
#   TIMEOUT  seconds after the reconnect until the catch-up counts as failed   (1800)
#   TRACE    file: also write "seconds_after_reconnect,received_bytes" to it twice a second   (unset)
#
# The cut-off drops every packet the node sends (tc netem loss 100%, see netem.sh), so it can neither ask
# for blocks nor answer. Prints one line:
#   <outage s> <slots behind at reconnect> <catch-up seconds> <MB received during the catch-up>
# or "<outage s> <slots behind> NA NA" if it did not catch up within TIMEOUT.
# "Caught up" is the same test as in sync-time.sh: the node's tip is at most 20 slots (20 s) behind the
# chain clock.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUTAGE=${1:?usage: $0 <outage seconds>}
NAME=${NAME:-cardano-joiner}; export NAME      # netem.sh reads it
TIMEOUT=${TIMEOUT:-1800}
MAX_BEHIND=20

GENESIS=$HERE/../../build/joiner/shelley-genesis.json
MAGIC=$(grep -o '"networkMagic": *[0-9]*' "$GENESIS" | grep -o '[0-9]*$')
SYSTEM_START=$(grep -o '"systemStart": *"[^"]*"' "$GENESIS" | cut -d'"' -f4)
CHAIN_START=$(date -u -d "$SYSTEM_START" +%s)

# slots between the chain clock and the node's tip (prints nothing if the node does not answer)
behind() {
  local slot
  slot=$(docker exec "$NAME" cardano-cli query tip --socket-path /node.socket --testnet-magic "$MAGIC" 2>/dev/null \
           | grep -o '"slot": *[0-9]*' | grep -o '[0-9]*$') || true
  [ -n "$slot" ] && echo $(( $(date +%s) - CHAIN_START - slot ))
}

# megabytes / bytes received so far on the node's network card
rx_mb()    { docker exec "$NAME" cat /proc/net/dev | awk -F'[: ]+' '$2 == "eth0" { printf "%.1f", $3 / 1048576 }'; }
rx_bytes() { docker exec "$NAME" cat /proc/net/dev | awk -F'[: ]+' '$2 == "eth0" { print $3 }'; }

# seconds since the reconnect, and whether $TIMEOUT has passed
elapsed()   { awk -v s="$START" -v n="$(date +%s.%N)" 'BEGIN { printf "%.1f", n - s }'; }
timed_out() { [ "$(awk -v s="$START" -v n="$(date +%s.%N)" -v t="$TIMEOUT" 'BEGIN { print (n - s > t) }')" = 1 ]; }

"$HERE/netem.sh" set 0 100               # cut off: every packet the node sends is dropped
sleep "$OUTAGE"
BEHIND=$(behind)
RX0=$(rx_mb)
"$HERE/netem.sh" set 0 0                 # reconnect
START=$(date +%s.%N)
[ -n "${TRACE:-}" ] && echo "seconds_after_reconnect,received_bytes" > "$TRACE"
until [ -n "$(behind)" ] && [ "$(behind)" -le "$MAX_BEHIND" ]; do
  timed_out && { echo "$OUTAGE $BEHIND NA NA"; exit 0; }
  [ -n "${TRACE:-}" ] && echo "$(elapsed),$(rx_bytes)" >> "$TRACE"
  sleep 0.5
done
awk -v o="$OUTAGE" -v b="$BEHIND" -v s="$START" -v e="$(date +%s.%N)" -v r0="$RX0" -v r1="$(rx_mb)" \
  'BEGIN { printf "%d %d %.1f %.1f\n", o, b, e - s, r1 - r0 }'
