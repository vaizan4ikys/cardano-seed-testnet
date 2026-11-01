#!/bin/bash
# Generate a fresh private Cardano testnet (genesis files, pool keys, funded
# addresses) into build/net-<N>/testnet/.
#
#   ./scripts/gen-testnet.sh          network 1
#   NET=2 ./scripts/gen-testnet.sh    network 2
#   PARAMS=mainnet ./scripts/gen-testnet.sh    mainnet-like chain parameters (see spec/README.md)
#
# The chain's start time is set 20 s from now, so all nodes agree on when it begins.
# The nodes must be started soon after (see "start-time window" in the README).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

POOLS=${POOLS:-3}

# SKIP_NTP_CHECK=1: for a machine that is itself the time source of the other machines (setup-clocks.sh)
timedatectl show -p NTPSynchronized --value | grep -q yes || [ "${SKIP_NTP_CHECK:-}" = 1 ] \
  || { echo "clock is not NTP-synced yet, wait and retry"; exit 1; }

rm -rf "$TESTNET"
mkdir -p "$BUILD"

START=$(date -u -d "+20 seconds" +%Y-%m-%dT%H:%M:%SZ)

# PARAMS=mainnet: a copy of spec/ with mainnet's block rhythm (f=0.05: one block per 20 s, k=2160,
# 432000-slot epochs, 90 KB blocks); the rest stays as in spec/
SPEC=$ROOT/spec
if [ "${PARAMS:-}" = mainnet ]; then
  SPEC=$BUILD/spec-mainnet
  rm -rf "$SPEC"; cp -r "$ROOT/spec" "$SPEC"
  python3 - "$SPEC/shelley-spec.json" <<'EOP'
import json, sys
s = json.load(open(sys.argv[1]))
s.update(activeSlotsCoeff=0.05, securityParam=2160, epochLength=432000)
s["protocolParams"]["maxBlockBodySize"] = 90112
json.dump(s, open(sys.argv[1], "w"), indent=2)
EOP
fi

# cardano-cli runs in a container; spec/ is mounted read-only, build/net-<N>/ is its output
docker run --rm --user "$(id -u):$(id -g)" --entrypoint cardano-cli \
  -v "$SPEC:/spec:ro" -v "$BUILD:/work" "$IMAGE" \
  conway genesis create-testnet-data \
    --spec-shelley /spec/shelley-spec.json \
    --spec-alonzo  /spec/alonzo-spec.json \
    --spec-conway  /spec/conway-spec.json \
    --pools "$POOLS" --stake-delegators "$POOLS" --utxo-keys 2 \
    --total-supply 45000000000000000 --delegated-supply 30000000000000000 \
    --testnet-magic "$MAGIC" --start-time "$START" --out-dir /work/testnet

cp "$ROOT/spec/config.json" "$TESTNET/config.json"
echo "net-$NET: testnet generated (magic $MAGIC), systemStart=$START"
