#!/bin/bash
# Runs on the VM that hosts pool 1 (seedvm). The submit step of gateway.py for the demo:
#   python3 gateway.py --submit command --submit-command "./submit_contract.sh {file} {hash}"
# Copies the batch file into pool 1's container and sends it through the contract as gateway $GATEWAY.
# The contract script it calls is experiments/contract/in-container/p1-batch.sh, which p0.sh copies to
# /tmp/p0-scripts in the container.
#
# Usage:  ./submit_contract.sh <batch-file> [<batch-hash>]       (the hash is given by gateway.py, not used here)
# Environment (defaults):
#   GATEWAY=A       which gateway wallet signs: A = on the list, B = not on the list
#   P0_DIR=/tmp/p0n work folder inside the container (the batch is copied to $P0_DIR/batches/)
#   NET=1           network number: picks the pool container and the network magic (scripts/lib.sh; net 1 = 42)
# Exit codes: 0 sent, 2 refused for good by the contract (gateway.py puts the batch into dead/),
#             1 or anything else = failed, gateway.py tries again later.
set -u

# --- settings ---
FILE=$1
HASH=${2:-}
GATEWAY=${GATEWAY:-A}
WORKDIR=${P0_DIR:-/tmp/p0n}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/scripts/lib.sh"      # sets NET, MAGIC and pool_container

# --- main part ---
container=$(pool_container 1)
[ -n "$container" ] || { echo "pool 1 is not running"; exit 1; }
batch_name=$(basename "$FILE")
docker exec "$container" mkdir -p "$WORKDIR/batches" || exit 1
docker cp "$FILE" "$container:$WORKDIR/batches/$batch_name" || exit 1
docker exec -e P0_DIR="$WORKDIR" -e GATEWAY="$GATEWAY" "$container" \
  bash /tmp/p0-scripts/p1-batch.sh "$MAGIC" "$WORKDIR/batches/$batch_name"
