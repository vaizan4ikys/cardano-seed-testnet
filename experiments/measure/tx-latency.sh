#!/bin/bash
# Latency of one transaction submitted at a remote node. Runs on your own machine (the Mac); the pool VM
# and the node's VM are reached over ssh. The drivers (run-all.sh, hops.sh, profiles.sh) call it.
#
# Usage:
#   ./tx-latency.sh <vm>                e.g. ./tx-latency.sh seedvm2
#
# Environment (default):
#   POOL   the VM that hosts the network      (POOL_HOST from scripts/config.sh)
#   NAME   container of the node on <vm>      (cardano-joiner; hops.sh uses hop1, hop2, ...)
#   NET    network number                     (1; network magic = 41 + NET, as in scripts/lib.sh)
#
# The pool machine builds and signs a metadata transaction (it holds the key, the joiners
# have none). <vm> submits it through its own node. Prints two numbers, comma separated:
#
#   <block seconds>,<mempool seconds>
#
#   block seconds    from submit on <vm> until the transaction is in a block that <vm> has
#                    (one clock: measured on <vm>)
#   mempool seconds  from submit on <vm> until the node on the pool machine holds it in its
#                    mempool: the time the transaction needs to travel, without the wait for a
#                    block. Compares the clocks of two machines (see setup-clocks.sh).
#                    NA if the transaction was already in a block when first looked for, or if it
#                    was seen before it was submitted (it came from somewhere else).
#
# Every call spends the output of the previous one, so run them one after another.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../../scripts/config.sh"            # POOL_HOST, REPO

VM=${1:?usage: $0 <vm>}
POOL=${POOL:-$POOL_HOST}
MAGIC=$((41 + ${NET:-1}))                         # same formula as scripts/lib.sh
METADATA="{\"674\": {\"msg\": [\"latency test via $VM\"]}}"

# stderr of ssh carries a harmless OpenSSH warning on the VMs; hide only that
ssh_quiet() { ssh -o BatchMode=yes "$@" 2> >(grep -v '^\*\*' >&2); }

# 1. build and sign on the pool machine: "txid: <id>" followed by the signed transaction
BUILT=$(ssh_quiet "$POOL" "cd $REPO && source scripts/lib.sh &&
  docker exec -i -e BUILD_ONLY=1 \"\$(require_pool 1)\" bash -s -- $MAGIC $(printf '%q' "$METADATA")" \
  < "$HERE/../../scripts/in-container/submit-metadata.sh")
TXID=$(sed -n 's/^txid: //p' <<< "$BUILT")
TX=$(sed -n '/^txid: /,$p' <<< "$BUILT" | sed 1d | tr -d '\n')
[ -n "$TXID" ] && [ -n "$TX" ] || { echo "could not build the transaction:" >&2; echo "$BUILT" >&2; exit 1; }
echo "txid $TXID" >&2

# 2. a watcher on the pool machine notes when the transaction reaches its mempool
WATCHED=$(mktemp)
ssh_quiet "$POOL" "cd $REPO && source scripts/lib.sh &&
  docker exec -i \"\$(require_pool 1)\" bash -s -- $MAGIC $TXID" \
  < "$HERE/in-container/watch-mempool.sh" > "$WATCHED" &
WATCHER=$!
sleep 1   # let it start before the transaction is submitted

# 3. submit it through the joiner on <vm> and time it there: "<submit time> <seconds>"
RESULT=$(ssh_quiet "$VM" "docker exec -i ${NAME:-cardano-joiner} bash -s -- $MAGIC $TXID $(printf '%q' "$TX")" \
  < "$HERE/in-container/submit-and-wait.sh")
wait "$WATCHER" || true

read -r SUBMITTED BLOCK_SECONDS <<< "$RESULT"
read -r SEEN WHERE < "$WATCHED" || true
rm -f "$WATCHED"
MEMPOOL_SECONDS=$(awk -v s="$SUBMITTED" -v m="${SEEN:-0}" -v w="${WHERE:-}" \
  'BEGIN { if (w == "mempool" && m >= s) printf "%.2f", m - s; else printf "NA" }')
echo "$BLOCK_SECONDS,$MEMPOOL_SECONDS"
