#!/bin/bash
# Runs on the VM that hosts pool 1 (seedvm). The submit step of gateway.py for the demo:
#   python3 gateway.py --submit command --submit-command "./submit_contract.sh {file} {hash}"
# Copies the batch file into pool 1's container and sends it through the contract as gateway $GATEWAY
# (A = on the list, B = not on the list). Exit codes: 0 sent, 2 refused for good by the contract, 1 failed (retry).
# Needs experiments/contract/in-container/*.sh in the container at /tmp/p0-scripts (p0.sh puts them there).
set -u
FILE=$1; HASH=${2:-}
G=${GATEWAY:-A}; WORK=${P0_DIR:-/tmp/p0n}; MAGIC=${MAGIC:-42}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/scripts/lib.sh"
C=$(pool_container 1)
[ -n "$C" ] || { echo "pool 1 is not running"; exit 1; }
BASE=$(basename "$FILE")
docker exec "$C" mkdir -p "$WORK/batches" || exit 1
docker cp "$FILE" "$C:$WORK/batches/$BASE" || exit 1
docker exec -e P0_DIR="$WORK" -e GATEWAY="$G" "$C" bash /tmp/p0-scripts/p1-batch.sh "$MAGIC" "$WORK/batches/$BASE"
