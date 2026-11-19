#!/bin/bash
# Generate a fresh private Cardano testnet (genesis files, pool keys, funded
# addresses) into build/net-<N>/testnet/. Runs on the machine that hosts the chain
# (needs docker and the seedemu-cardano image; called by ../run.sh).
#
#   ./scripts/gen-testnet.sh          network 1
#   NET=2 ./scripts/gen-testnet.sh    network 2
#   PARAMS=mainnet ./scripts/gen-testnet.sh    mainnet-like chain parameters (see spec/README.md)
#   PV=9 ./scripts/gen-testnet.sh              protocol version 9 (needed for Plutus V3 scripts; default 2)
#   POOLS=3                                    number of stake pools (default 3; cardano.py builds three)
#   SKIP_NTP_CHECK=1                           skip the clock check (for the machine that IS the time source,
#                                              see setup-clocks.sh)
#
# The chain's start time is set 20 s from now, so all nodes agree on when it begins.
# The nodes must be started soon after (see "start-time window" in the README).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# ---- settings ----
POOLS=${POOLS:-3}
START_DELAY="+20 seconds"                  # chain start time = now + this
TOTAL_SUPPLY=45000000000000000             # lovelace in the whole chain
DELEGATED_SUPPLY=30000000000000000         # lovelace delegated to the pools
UTXO_KEYS=2                                # funded payment addresses: utxo1, utxo2

# ---- functions ----

# PARAMS=mainnet: put a copy of spec/ with mainnet's block rhythm into $SPEC (f=0.05: one block per 20 s,
# k=2160, 432000-slot epochs, 90 KB blocks); the rest stays as in spec/
use_mainnet_spec() {
  SPEC=$BUILD/spec-mainnet
  rm -rf "$SPEC"; cp -r "$ROOT/spec" "$SPEC"
  python3 - "$SPEC/shelley-spec.json" <<'EOP'
import json, sys
s = json.load(open(sys.argv[1]))
s.update(activeSlotsCoeff=0.05, securityParam=2160, epochLength=432000)
s["protocolParams"]["maxBlockBodySize"] = 90112
json.dump(s, open(sys.argv[1], "w"), indent=2)
EOP
}

# PV=9: protocol version $PV instead of 2 (Plutus V3 scripts need version 9 or higher);
# everything else stays as in spec/ (or as in the mainnet copy above)
use_protocol_version() {
  if [ "$SPEC" = "$ROOT/spec" ]; then SPEC=$BUILD/spec-pv; rm -rf "$SPEC"; cp -r "$ROOT/spec" "$SPEC"; fi
  python3 - "$SPEC/shelley-spec.json" "$PV" <<'EOP'
import json, sys
s = json.load(open(sys.argv[1]))
s["protocolParams"]["protocolVersion"] = {"major": int(sys.argv[2]), "minor": 0}
json.dump(s, open(sys.argv[1], "w"), indent=2)
EOP
}

# ---- main ----

# SKIP_NTP_CHECK=1: for a machine that is itself the time source of the other machines (setup-clocks.sh)
timedatectl show -p NTPSynchronized --value | grep -q yes || [ "${SKIP_NTP_CHECK:-}" = 1 ] \
  || { echo "clock is not NTP-synced yet, wait and retry"; exit 1; }

rm -rf "$TESTNET"
mkdir -p "$BUILD"

START=$(date -u -d "$START_DELAY" +%Y-%m-%dT%H:%M:%SZ)

SPEC=$ROOT/spec                            # folder with the genesis templates (replaced by a copy below if needed)
if [ "${PARAMS:-}" = mainnet ]; then use_mainnet_spec; fi
if [ -n "${PV:-}" ]; then use_protocol_version; fi

# cardano-cli runs in a container; spec/ is mounted read-only, build/net-<N>/ is its output
docker run --rm --user "$(id -u):$(id -g)" --entrypoint cardano-cli \
  -v "$SPEC:/spec:ro" -v "$BUILD:/work" "$IMAGE" \
  conway genesis create-testnet-data \
    --spec-shelley /spec/shelley-spec.json \
    --spec-alonzo  /spec/alonzo-spec.json \
    --spec-conway  /spec/conway-spec.json \
    --pools "$POOLS" --stake-delegators "$POOLS" --utxo-keys "$UTXO_KEYS" \
    --total-supply "$TOTAL_SUPPLY" --delegated-supply "$DELEGATED_SUPPLY" \
    --testnet-magic "$MAGIC" --start-time "$START" --out-dir /work/testnet

cp "$ROOT/spec/config.json" "$TESTNET/config.json"
echo "net-$NET: testnet generated (magic $MAGIC), systemStart=$START"
