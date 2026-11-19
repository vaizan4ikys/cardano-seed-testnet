#!/bin/bash
# A rogue node: a block producer of a SECOND chain that uses the same network magic as ours but its own
# genesis (own keys, own pool, own start time). It dials a pool of the real network. Does the real network
# accept it, and does it notice anything? Runs ON a spare machine (a chain VM, seedvm3 in our lab);
# outsider.sh starts it over ssh.
#
# Usage:
#   ./rogue.sh gen [magic]                  new rogue genesis + pool keys in build/rogue-<magic>/ (default magic 42,
#                                           the real network's: identical handshake, different chain)
#   ./rogue.sh start <peer-ip> [port]       start the rogue node, dialling <peer-ip>:<port> (default 3001)
#   ./rogue.sh stop
#   ./rogue.sh tip                          the rogue chain's tip
#   ./rogue.sh log                          the rogue node's log
#
# "gen" and "start" belong together: the chain starts 20 s after "gen", so start the node right away.
# "gen" remembers its magic and folder in build/rogue-magic and build/rogue-dir for the other commands.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
IMAGE=seedemu-cardano:local
NAME=cardano-rogue

# new genesis and pool keys for the rogue network
gen() {   # magic
  local magic=$1
  local dir=$ROOT/build/rogue-$magic
  rm -rf "$dir"; mkdir -p "$dir"
  local start
  start=$(date -u -d "+20 seconds" +%Y-%m-%dT%H:%M:%SZ)
  docker run --rm --user "$(id -u):$(id -g)" --entrypoint cardano-cli \
    -v "$ROOT/spec:/spec:ro" -v "$dir:/work" "$IMAGE" \
    conway genesis create-testnet-data \
      --spec-shelley /spec/shelley-spec.json --spec-alonzo /spec/alonzo-spec.json --spec-conway /spec/conway-spec.json \
      --pools 1 --stake-delegators 1 --utxo-keys 1 \
      --total-supply 45000000000000000 --delegated-supply 30000000000000000 \
      --testnet-magic "$magic" --start-time "$start" --out-dir /work/testnet
  # same config as the real network, plus the connection traces we want to see
  python3 - "$ROOT/spec/config.json" "$dir/testnet/config.json" <<'EOP'
import json, sys
c = json.load(open(sys.argv[1]))
for ns in ("Net.ConnectionManager", "Net.Handshake", "Net.InboundGovernor", "ChainSync.Client"):
    c["TraceOptions"][ns] = {"severity": "Info"}
json.dump(c, open(sys.argv[2], "w"), indent=2)
EOP
  echo "$magic" > "$ROOT/build/rogue-magic"; echo "$magic" > "$ROOT/build/rogue-dir"
  echo "rogue genesis (magic $magic) in $dir, chain starts at $start"
}

# start the rogue node on the genesis made by the last "gen"
start() {   # peer-ip port
  local peer=$1 port=$2
  local dir keys
  dir=$ROOT/build/rogue-$(cat "$ROOT/build/rogue-dir")/testnet
  keys=/chain/pools-keys/pool1       # inside the container
  cat > "$dir/topology.json" <<EOT
{ "localRoots": [ { "accessPoints": [ { "address": "$peer", "port": $port } ], "advertise": false, "trustable": true, "hotValency": 1 } ],
  "publicRoots": [], "useLedgerAfterSlot": -1 }
EOT
  local node_command="mkdir -p /db && exec cardano-node run --config /chain/config.json --topology /chain/topology.json"
  node_command="$node_command --database-path /db --socket-path /node.socket --host-addr 0.0.0.0 --port 3001"
  node_command="$node_command --shelley-kes-key $keys/kes.skey --shelley-vrf-key $keys/vrf.skey"
  node_command="$node_command --shelley-operational-certificate $keys/opcert.cert"
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run -d --name "$NAME" -v "$dir:/chain" --entrypoint sh "$IMAGE" -c "$node_command" >/dev/null
  echo "rogue node started, dialling $peer:$port"
}

case ${1:-} in
  gen)   gen "${2:-42}" ;;
  start) start "${2:?usage: $0 start <peer-ip> [port]}" "${3:-3001}" ;;
  stop)  docker rm -f "$NAME" >/dev/null 2>&1 && echo "removed $NAME" || echo "$NAME is not running" ;;
  tip)   docker exec "$NAME" cardano-cli query tip --socket-path /node.socket \
           --testnet-magic "$(cat "$ROOT/build/rogue-magic")" ;;
  log)   docker logs "$NAME" 2>&1 ;;
  *)     sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 1 ;;
esac
