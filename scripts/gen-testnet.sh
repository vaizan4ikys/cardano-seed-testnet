#!/bin/bash
# Generate a fresh private Cardano testnet (genesis files, pool keys, funded
# addresses) into build/net-<N>/testnet/.
#
#   ./scripts/gen-testnet.sh          network 1
#   NET=2 ./scripts/gen-testnet.sh    network 2
#
# The chain's start time is set 20 s from now, so all nodes agree on when it begins.
# The nodes must be started soon after (see "start-time window" in the README).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

POOLS=${POOLS:-3}

timedatectl show -p NTPSynchronized --value | grep -q yes \
  || { echo "clock is not NTP-synced yet, wait and retry"; exit 1; }

rm -rf "$TESTNET"
mkdir -p "$BUILD"

START=$(date -u -d "+20 seconds" +%Y-%m-%dT%H:%M:%SZ)

# cardano-cli runs in a container; spec/ is mounted read-only, build/net-<N>/ is its output
docker run --rm --user "$(id -u):$(id -g)" --entrypoint cardano-cli \
  -v "$ROOT/spec:/spec:ro" -v "$BUILD:/work" "$IMAGE" \
  conway genesis create-testnet-data \
    --spec-shelley /spec/shelley-spec.json \
    --spec-alonzo  /spec/alonzo-spec.json \
    --spec-conway  /spec/conway-spec.json \
    --pools "$POOLS" --stake-delegators "$POOLS" --utxo-keys 2 \
    --total-supply 45000000000000000 --delegated-supply 30000000000000000 \
    --testnet-magic "$MAGIC" --start-time "$START" --out-dir /work/testnet

cp "$ROOT/spec/config.json" "$TESTNET/config.json"
echo "net-$NET: testnet generated (magic $MAGIC), systemStart=$START"
