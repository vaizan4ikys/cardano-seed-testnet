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

# Lines starting with ">>> " name the phase; experiments/demo/fresh.sh shows the latest one while run.sh runs.

# the node image is built once; later runs reuse it
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo ">>> building the node image $IMAGE (first time only: downloads the cardano-node and SEED base images)"
  docker build -t "$IMAGE" "$ROOT/image"
fi

# remove the previous chain of this network, if any
echo ">>> removing the previous chain"
"$ROOT/stop.sh"
rm -rf "$SENT"   # messages sent to the old chain: their txids do not exist on the new one

# genesis files and keys, then the SEED emulation (cardano.py writes the docker-compose files into $OUTPUT)
echo ">>> genesis files and keys"
"$ROOT/scripts/gen-testnet.sh"
# seedemu is found through PYTHONPATH (default: ~/seed-emulator);
# the Python is the one of ~/seed-venv if it exists (see scripts/tools.sh)
[ -d "$SEED_EMULATOR/seedemu" ] && export PYTHONPATH="$SEED_EMULATOR${PYTHONPATH:+:$PYTHONPATH}"
echo ">>> compiling the SEED emulation (cardano.py)"
"$(seed_python)" "$ROOT/cardano.py"

# Give every service folder its own file time. Why: SEED writes all files within one clock tick, so the files of
# different services have the same name, size and time, and the legacy builder that "docker compose" uses when the
# buildx plugin is missing (Ubuntu's docker.io package) then puts one service's file into ANOTHER service's image
# (19 Nov 2026: 28 of 30 test images got a wrong file; 0 of 30 with one time per folder).
"$ROOT/scripts/check-images.sh" --stamp

# bring the containers up
echo ">>> building the images of about 37 containers and starting them (first time: downloads the SEED images)"
(cd "$OUTPUT" && docker compose -p "$PROJECT" up -d)
# docker reuses existing images: make sure every container really has the files generated for it (repairs if not)
echo ">>> checking the files inside the containers"
"$ROOT/scripts/check-images.sh"
if [ "${EXPOSE:-}" = 1 ]; then
  expose_rule add
  echo "pool 1 is reachable from other machines on port $((3000 + NET))"
fi
echo "net-$NET started. Check it with: NET=$NET ./scripts/check.sh"
