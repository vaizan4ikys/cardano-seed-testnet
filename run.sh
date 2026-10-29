#!/bin/bash
# Start a fresh private Cardano testnet inside SEED:
# generate the genesis, compile the emulation, bring the containers up.
# Every run starts a NEW chain; the old one is removed.
#
#   ./run.sh          network 1 (magic 42)
#   NET=2 ./run.sh    network 2 (magic 43), can run next to network 1
#
# Check it with ./scripts/check.sh, stop it with ./stop.sh.
set -euo pipefail
source "$(dirname "$0")/scripts/lib.sh"

# building ~30 images at once can time out (DeadlineExceeded), so build fewer in parallel
export COMPOSE_PARALLEL_LIMIT=${COMPOSE_PARALLEL_LIMIT:-3}

docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -t "$IMAGE" "$ROOT/image"

# remove the previous chain of this network, if any
"$ROOT/stop.sh"
rm -rf "$SENT"   # messages sent to the old chain: their txids do not exist on the new one

"$ROOT/scripts/gen-testnet.sh"
python3 "$ROOT/cardano.py"

(cd "$OUTPUT" && docker compose -p "$PROJECT" up -d)
echo "net-$NET started. Check it with: NET=$NET ./scripts/check.sh"
