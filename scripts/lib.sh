# Shared settings and helpers. Every script starts with:
#
#     source "$(dirname "$0")/lib.sh"          (scripts/ folder)
#
# Pick the network with the NET variable (default 1):
#
#     ./run.sh             network 1: magic 42, pools in AS150-152
#     NET=2 ./run.sh       network 2: magic 43, pools in AS200-202
#
# Both networks can run side by side on one machine: they share no container
# names, subnets or ports, and each keeps its files in build/net-<N>/.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

NET=${NET:-1}
MAGIC=$((41 + NET))                  # network magic: 42, 43, ...
FIRST_AS=$((150 + 50 * (NET - 1)))   # AS of pool 1: 150, 200, ...
PROJECT=cardano-net-$NET             # docker compose project name
IMAGE=seedemu-cardano:local
SOCKET=/node.socket                  # node socket inside the pool containers

# display name of the pool hosts: Cardano-Pool-1 (net 1), Cardano2-Pool-1 (net 2), ...
if [ "$NET" -eq 1 ]; then LABEL=Cardano; else LABEL=Cardano$NET; fi

BUILD=$ROOT/build/net-$NET
TESTNET=$BUILD/testnet               # genesis files and keys (generated)
OUTPUT=$BUILD/output                 # docker-compose files written by cardano.py (generated)
SENT=$BUILD/sent                     # copies of the metadata messages sent to the chain

# name of the running container of pool N (1, 2 or 3)
pool_container() {
  docker ps --format '{{.Names}}' | grep "^as$((FIRST_AS + $1 - 1))h-$LABEL-Pool-$1-" | head -1 || true
}

# same, but stop with an error if the pool is not running
require_pool() {
  local c
  c=$(pool_container "$1")
  [ -n "$c" ] || { echo "pool $1 of net-$NET is not running (start it with: NET=$NET ./run.sh)" >&2; exit 1; }
  echo "$c"
}

# name of the running SEED router container in front of pool N
pool_router() {
  docker ps --format '{{.Names}}' | grep "^as$((FIRST_AS + $1 - 1))r-router0-" | head -1 || true
}

# chain tip of pool N as one compact line
tip_of() {
  docker exec "$(require_pool "$1")" cardano-cli query tip \
    --socket-path "$SOCKET" --testnet-magic "$MAGIC" 2>&1 | tr -d ' \n'
  echo
}

# EXPOSE=1: let nodes on OTHER machines join through pool 1 (host port 3001, 3002, ...).
# Docker forwards their packets into the SEED network, but the pool answers through its SEED
# router, which cannot reach the outside, so the reply would be lost. Rewriting the source
# address of those packets makes the pool answer through the docker bridge instead.
#   expose_rule add | del      (needs sudo; "del" never asks for a password)
expose_rule() {
  local rule=(POSTROUTING -p tcp -d "10.$FIRST_AS.0.71" --dport 3001 -j MASQUERADE)
  if [ "$1" = add ]; then
    sudo iptables -t nat -C "${rule[@]}" 2>/dev/null || sudo iptables -t nat -A "${rule[@]}"
  else
    while sudo -n iptables -t nat -D "${rule[@]}" 2>/dev/null; do :; done
  fi
}
