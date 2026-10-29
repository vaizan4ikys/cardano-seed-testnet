#!/bin/bash
# Add ONE extra Cardano node (a plain docker container, outside SEED) to the
# machine and let it join a running network by dialling pool 1 of that network.
#
#   ./join.sh 1       join network 1 (magic 42), the node syncs the chain
#   ./join.sh 2       join network 2 (magic 43)
#   ./join.sh stop    remove the container
#
# The container gets the address .99 in the AS of pool 1 (10.150.0.99 for
# network 1, 10.200.0.99 for network 2) and dials pool 1 at .71:3001.
# It has no pool keys, so it only follows the chain.
#
# Run ./join.sh stop before ./run.sh of that network: docker cannot delete a
# network that still has a container attached.
set -euo pipefail

NAME=cardano-joiner

case ${1:-} in
  stop) docker rm -f "$NAME" >/dev/null 2>&1 && echo "removed $NAME" || echo "$NAME is not running"; exit 0 ;;
  [0-9]*) export NET=$1 ;;
  *) echo "usage: $0 <network number>   |   $0 stop"; exit 1 ;;
esac
source "$(dirname "$0")/../../scripts/lib.sh"

DOCKER_NET=${PROJECT}_net_${FIRST_AS}_net0   # the docker network of pool 1's AS
IP=10.$FIRST_AS.0.99
PEER=10.$FIRST_AS.0.71
WORK=$BUILD/joiner

docker network inspect "$DOCKER_NET" >/dev/null 2>&1 \
  || { echo "network $DOCKER_NET not found: is net-$NET running?"; exit 1; }
docker rm -f "$NAME" >/dev/null 2>&1 || true

# only the public chain files go into the container, no keys
rm -rf "$WORK" && mkdir -p "$WORK"
cp "$TESTNET"/config.json "$TESTNET"/*-genesis.json "$WORK/"
cat > "$WORK/topology.json" <<EOT
{
  "localRoots": [ { "accessPoints": [ { "address": "$PEER", "port": 3001 } ],
                    "advertise": false, "trustable": true, "hotValency": 1 } ],
  "publicRoots": [],
  "useLedgerAfterSlot": -1
}
EOT

# the same labels SEED puts on its nodes, so the Internet map shows the container too
L=org.seedsecuritylabs.seedemu.meta
docker run -d --name "$NAME" --network "$DOCKER_NET" --ip "$IP" \
  --label $L.asn="$FIRST_AS" --label $L.nodename=joiner --label $L.role=Host \
  --label $L.displayname=Cardano-Joiner \
  --label $L.net.0.name=net0 --label $L.net.0.address="$IP/24" \
  -v "$WORK:/genesis:ro" --entrypoint sh "$IMAGE" -c \
  'mkdir -p /db && exec cardano-node run --config /genesis/config.json --topology /genesis/topology.json --database-path /db --socket-path /node.socket --host-addr 0.0.0.0 --port 3001' >/dev/null
echo "started $NAME ($IP) on net-$NET, dialling $PEER (magic $MAGIC); see ./check.sh"
