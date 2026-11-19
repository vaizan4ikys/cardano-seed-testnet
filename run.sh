#!/bin/bash
# Start a fresh private Cardano testnet inside SEED: generate the genesis, compile the emulation,
# bring the containers up. Runs on the machine that hosts the chain (needs docker).
# Every run starts a NEW chain; the old one is removed.
#
#   ./run.sh          network 1 (magic 42)
#   NET=2 ./run.sh    network 2 (magic 43), can run next to network 1
#   EXPOSE=1 ./run.sh pool 1 also reachable from other machines on port 3001 (3002 for net 2)
#   PARAMS=mainnet / PV=9 / SKIP_NTP_CHECK=1 ./run.sh    handed on to scripts/gen-testnet.sh (see there)
#   COMPOSE_PARALLEL_LIMIT=3                             images docker builds at the same time (default 3)
#   SEED_EMULATOR, SEED_PYTHON                           where seed-emulator and its Python are (see scripts/tools.sh)
#
# Check it with ./scripts/check.sh, stop it with ./stop.sh.
set -euo pipefail
source "$(dirname "$0")/scripts/lib.sh"
source "$ROOT/scripts/tools.sh"   # seed_python, SEED_EMULATOR

# building ~30 images at once can time out (DeadlineExceeded), so build fewer in parallel
export COMPOSE_PARALLEL_LIMIT=${COMPOSE_PARALLEL_LIMIT:-3}

# the node image is built once; later runs reuse it
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -t "$IMAGE" "$ROOT/image"

# remove the previous chain of this network, if any
"$ROOT/stop.sh"
rm -rf "$SENT"   # messages sent to the old chain: their txids do not exist on the new one

# genesis files and keys, then the SEED emulation (cardano.py writes the docker-compose files into $OUTPUT)
"$ROOT/scripts/gen-testnet.sh"
# seedemu is found through PYTHONPATH (default: ~/seed-emulator);
# the Python is the one of ~/seed-venv if it exists (see scripts/tools.sh)
[ -d "$SEED_EMULATOR/seedemu" ] && export PYTHONPATH="$SEED_EMULATOR${PYTHONPATH:+:$PYTHONPATH}"
"$(seed_python)" "$ROOT/cardano.py"

# bring the containers up
(cd "$OUTPUT" && docker compose -p "$PROJECT" up -d)
# docker reuses existing images: make sure every container really has the files generated for it (repairs if not)
"$ROOT/scripts/check-images.sh"
if [ "${EXPOSE:-}" = 1 ]; then
  expose_rule add
  echo "pool 1 is reachable from other machines on port $((3000 + NET))"
fi
echo "net-$NET started. Check it with: NET=$NET ./scripts/check.sh"
