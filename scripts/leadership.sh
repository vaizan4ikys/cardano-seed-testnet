#!/bin/bash
# Show the slots a pool will lead (the slots its VRF lottery won).
# Runs on the machine that hosts the chain; the query itself runs inside the pool's container.
#
#   ./scripts/leadership.sh              pool 1, current epoch
#   ./scripts/leadership.sh 2            pool 2, current epoch
#   ./scripts/leadership.sh 3 next       pool 3, next epoch
#   NET=2 ./scripts/leadership.sh        network 2
#
# "next" only works in the last ~900 slots of an epoch (otherwise: PastHorizon).
set -eo pipefail
source "$(dirname "$0")/lib.sh"

# ---- arguments ----
N=${1:-1}               # pool number
WHEN=${2:-current}      # current | next
case $WHEN in current|next) ;; *) echo "second argument must be 'current' or 'next'"; exit 1 ;; esac

SHOWN=10                # how many leader slots are listed one by one
POOL=$(require_pool "$N")

# The query runs inside the pool's container, with that pool's own keys. $N, $MAGIC and $WHEN are filled in
# here; the \$ ones are evaluated inside the container.
QUERY="
  KEYS=/cardano/pools-keys/pool$N
  POOL_ID=\$(cardano-cli conway stake-pool id --cold-verification-key-file \$KEYS/cold.vkey --output-format bech32)
  cardano-cli conway query leadership-schedule --testnet-magic $MAGIC \
    --genesis /cardano/shelley-genesis.json --stake-pool-id \$POOL_ID \
    --vrf-signing-key-file \$KEYS/vrf.skey --$WHEN --output-json"
OUT=$(docker exec -e CARDANO_NODE_SOCKET_PATH="$SOCKET" "$POOL" bash -c "$QUERY" 2>&1) || true

# a successful answer is a JSON list; anything else is an error message
if [[ $OUT != \[* ]]; then
  echo "query failed:"; echo "$OUT" | head -2 | cut -c1-200
  [[ $OUT == *PastHorizon* ]] && echo "(the next epoch is not visible yet; try again when fewer than ~900 slots remain)"
  exit 1
fi

echo "$OUT" | python3 -c "
import json, sys
slots = json.load(sys.stdin)
print('pool $N, $WHEN epoch:', len(slots), 'leader slots')
for s in slots[:$SHOWN]: print('  slot', s['slotNumber'], s['slotTime'])
if len(slots) > $SHOWN:
    print('  ...', len(slots) - $SHOWN, 'more; last: slot', slots[-1]['slotNumber'], slots[-1]['slotTime'])
"
