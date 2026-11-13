#!/bin/bash
# Runs on a SITE machine (seedvm2/3/4). Submit step of gateway.py: sends one batch file through the contract using the
# gateway's own node (the container $SITE) and its own wallet (gateway $GATEWAY, key made inside that container).
#   python3 gateway.py ... --submit command --submit-command "./submit_site.sh {file} {hash}"   (env SITE, GATEWAY, EXU)
# Exit codes as p1-batch.sh: 0 sent, 2 refused for good by the contract, 1 failed (retry).
set -u
FILE=$1; HASH=${2:-}
C=${SITE:?SITE (container name) not set}; G=${GATEWAY:?GATEWAY not set}; WORK=/tmp/p0n; MAGIC=${MAGIC:-42}
BASE=$(basename "$FILE")
docker exec "$C" mkdir -p "$WORK/batches" || exit 1
docker cp "$FILE" "$C:$WORK/batches/$BASE" || exit 1
# EXU: execution units declared for the script; must cover the registry size (Phase 3: 10 keys need (40.6 M steps, 132 k memory))
docker exec -e P0_DIR="$WORK" -e GATEWAY="$G" -e EXU="${EXU:-(40600000,132100)}" "$C" bash /tmp/p0-scripts/p1-batch.sh "$MAGIC" "$WORK/batches/$BASE"
