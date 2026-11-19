#!/bin/bash
# Runs on a SITE machine (seedvm2/3/4). Submit step of gateway.py: sends one batch file through the contract using the
# gateway's own node (the container $SITE) and its own wallet (gateway $GATEWAY, key made inside that container).
#   python3 gateway.py ... --submit command --submit-command "./submit_site.sh {file} {hash}"   (env SITE, GATEWAY, EXU)
# Environment: SITE (container name), GATEWAY (G3..G5), EXU (execution units, see below), MAGIC (default 42).
# Exit codes as p1-batch.sh: 0 sent, 2 refused for good by the contract, 1 failed (retry).
set -u
FILE=$1; HASH=${2:-}
CONTAINER=${SITE:?SITE (container name) not set}; GW=${GATEWAY:?GATEWAY not set}
WORK=/tmp/p0n                       # the work folder of the contract scripts inside the site container (P0_DIR)
MAGIC=${MAGIC:-42}
BASE=$(basename "$FILE")

# copy the batch file into the container, then let p1-batch.sh send it
docker exec "$CONTAINER" mkdir -p "$WORK/batches" || exit 1
docker cp "$FILE" "$CONTAINER:$WORK/batches/$BASE" || exit 1
# EXU: execution units declared for the script; must cover the registry size (Phase 3: 10 keys need (40.6 M steps, 132 k memory))
docker exec -e P0_DIR="$WORK" -e GATEWAY="$GW" -e EXU="${EXU:-(40600000,132100)}" "$CONTAINER" \
  bash /tmp/p0-scripts/p1-batch.sh "$MAGIC" "$WORK/batches/$BASE"
