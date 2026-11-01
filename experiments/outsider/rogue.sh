#!/bin/bash
# A rogue node: a block producer of a SECOND chain that uses the same network magic as ours but its
# own genesis (own keys, own pool, own start time). It dials a pool of the real network. Does the real
# network accept it, and does it notice anything? Run it on a spare machine (seedvm3).
#
#   ./rogue.sh gen [magic]                  new rogue genesis + pool keys in build/rogue-<magic>/ (default magic 42,
#                                           the real network's: identical handshake, different chain)
#   ./rogue.sh start <peer-ip> [port]       start the rogue node, dialling <peer-ip>:<port> (default 3001)
#   ./rogue.sh stop
#   ./rogue.sh tip                          the rogue chain's tip
#   ./rogue.sh log                          the rogue node's log
#
# "gen" and "start" belong together: the chain starts 20 s after "gen", so start the node right away.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
IMAGE=seedemu-cardano:local
NAME=cardano-rogue

case ${1:-} in
  gen)
    ARG=${2:-42}; MAGIC=$ARG
    DIR=$ROOT/build/rogue-$ARG
    rm -rf "$DIR"; mkdir -p "$DIR"
    START=$(date -u -d "+20 seconds" +%Y-%m-%dT%H:%M:%SZ)
    docker run --rm --user "$(id -u):$(id -g)" --entrypoint cardano-cli \
      -v "$ROOT/spec:/spec:ro" -v "$DIR:/work" "$IMAGE" \
      conway genesis create-testnet-data \
        --spec-shelley /spec/shelley-spec.json --spec-alonzo /spec/alonzo-spec.json --spec-conway /spec/conway-spec.json \
        --pools 1 --stake-delegators 1 --utxo-keys 1 \
        --total-supply 45000000000000000 --delegated-supply 30000000000000000 \
        --testnet-magic "$MAGIC" --start-time "$START" --out-dir /work/testnet
    # same config as the real network; the node logs the connection traces we want to see
    python3 - "$ROOT/spec/config.json" "$DIR/testnet/config.json" <<'EOP'
import json, sys
c = json.load(open(sys.argv[1]))
for ns in ("Net.ConnectionManager", "Net.Handshake", "Net.InboundGovernor", "ChainSync.Client"):
    c["TraceOptions"][ns] = {"severity": "Info"}
json.dump(c, open(sys.argv[2], "w"), indent=2)
EOP
    echo "$MAGIC" > "$ROOT/build/rogue-magic"; echo "$ARG" > "$ROOT/build/rogue-dir"
    echo "rogue genesis (magic $MAGIC) in $DIR, chain starts at $START" ;;
  start)
    PEER=${2:?usage: $0 start <peer-ip> [port]}; PORT=${3:-3001}
    DIR=$ROOT/build/rogue-$(cat "$ROOT/build/rogue-dir")/testnet
    cat > "$DIR/topology.json" <<EOT
{ "localRoots": [ { "accessPoints": [ { "address": "$PEER", "port": $PORT } ], "advertise": false, "trustable": true, "hotValency": 1 } ],
  "publicRoots": [], "useLedgerAfterSlot": -1 }
EOT
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    K=/chain/pools-keys/pool1
    docker run -d --name "$NAME" -v "$DIR:/chain" --entrypoint sh "$IMAGE" -c \
      "mkdir -p /db && exec cardano-node run --config /chain/config.json --topology /chain/topology.json --database-path /db --socket-path /node.socket --host-addr 0.0.0.0 --port 3001 --shelley-kes-key $K/kes.skey --shelley-vrf-key $K/vrf.skey --shelley-operational-certificate $K/opcert.cert" >/dev/null
    echo "rogue node started, dialling $PEER:$PORT" ;;
  stop) docker rm -f "$NAME" >/dev/null 2>&1 && echo "removed $NAME" || echo "$NAME is not running" ;;
  tip)  docker exec "$NAME" cardano-cli query tip --socket-path /node.socket --testnet-magic "$(cat "$ROOT/build/rogue-magic")" ;;
  log)  docker logs "$NAME" 2>&1 ;;
  *)    sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 1 ;;
esac
