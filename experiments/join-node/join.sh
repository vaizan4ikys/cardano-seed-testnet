#!/bin/bash
# Run ONE extra Cardano node (a plain docker container, no pool keys) that joins a running
# network and syncs its chain. It starts with an empty database every time.
#
#   ./join.sh local 1              same machine: attach to network 1 and dial its pool 1
#   ./join.sh local 2              the same for network 2
#   ./join.sh remote <host-ip>     another machine: dial <host-ip>:3001 over the real network
#   ./join.sh remote <host-ip> 3002   other port (network 2 is published on 3002)
#   ./join.sh stop                 remove the container
#
# local   the node gets the address .99 in the docker network of pool 1's AS and carries the SEED
#         labels, so it also shows up on the Internet map. Remove it (./join.sh stop) before
#         ./run.sh of that network: docker cannot delete a network with a container attached.
# remote  needs the chain files from ./fetch-chain-files.sh and, on the host, EXPOSE=1 ./run.sh.
set -euo pipefail

NAME=cardano-joiner
MODE=${1:-}

case $MODE in
  stop)   docker rm -f "$NAME" >/dev/null 2>&1 && echo "removed $NAME" || echo "$NAME is not running"; exit 0 ;;
  local)  export NET=${2:?usage: $0 local <network number>} ;;
  remote) ;;
  *)      sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 1 ;;
esac
source "$(dirname "$0")/../../scripts/lib.sh"

FILES=$ROOT/build/joiner            # chain files given to the node (no keys)
RUN_OPTIONS=()                      # extra options of "docker run"

if [ "$MODE" = local ]; then
  DOCKER_NET=${PROJECT}_net_${FIRST_AS}_net0     # the docker network of pool 1's AS
  IP=10.$FIRST_AS.0.99
  PEER=10.$FIRST_AS.0.71
  PORT=3001
  docker network inspect "$DOCKER_NET" >/dev/null 2>&1 \
    || { echo "network $DOCKER_NET not found: is net-$NET running?"; exit 1; }

  rm -rf "$FILES" && mkdir -p "$FILES"
  cp "$TESTNET"/config.json "$TESTNET"/*-genesis.json "$FILES/"

  # the same labels SEED puts on its nodes, so the Internet map shows the container too
  L=org.seedsecuritylabs.seedemu.meta
  RUN_OPTIONS=(--network "$DOCKER_NET" --ip "$IP"
    --label $L.asn="$FIRST_AS" --label $L.nodename=joiner --label $L.role=Host
    --label $L.displayname=Cardano-Joiner
    --label $L.net.0.name=net0 --label $L.net.0.address="$IP/24")
else
  PEER=${2:?usage: $0 remote <host-ip> [port]}
  PORT=${3:-3001}
  [ -f "$FILES/config.json" ] || { echo "no chain files: run ./fetch-chain-files.sh <user@host> first"; exit 1; }
fi
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "image $IMAGE not found"; exit 1; }

# the node dials only this one peer
cat > "$FILES/topology.json" <<EOT
{
  "localRoots": [ { "accessPoints": [ { "address": "$PEER", "port": $PORT } ],
                    "advertise": false, "trustable": true, "hotValency": 1 } ],
  "publicRoots": [],
  "useLedgerAfterSlot": -1
}
EOT

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" "${RUN_OPTIONS[@]}" -v "$FILES:/chain:ro" --entrypoint sh "$IMAGE" -c \
  'mkdir -p /db && exec cardano-node run --config /chain/config.json --topology /chain/topology.json --database-path /db --socket-path /node.socket --host-addr 0.0.0.0 --port 3001' >/dev/null
MAGIC=$(grep -o '"networkMagic": *[0-9]*' "$FILES/shelley-genesis.json" | grep -o '[0-9]*$')
echo "started $NAME ($MODE), dialling $PEER:$PORT, magic $MAGIC; see ./check.sh"
