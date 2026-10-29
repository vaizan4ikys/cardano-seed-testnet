#!/bin/bash
# Copy the PUBLIC chain files (config + genesis files, no keys) of a running network from the
# machine that hosts it. Run this on the machine of the remote node.
#
#   ./fetch-chain-files.sh seed@<host-ip>          network 1
#   ./fetch-chain-files.sh seed@<host-ip> 2        network 2
#   REMOTE_REPO=path/to/repo ./fetch-chain-files.sh ... if the repo is not in ~/cardano-seed-testnet
#
# They end up in build/joiner/. Needs SSH access to the host (use "ssh -A" to borrow your key).
set -euo pipefail
source "$(dirname "$0")/../../scripts/lib.sh"

HOST=${1:?usage: $0 <user@host> [network number]}
NETWORK=${2:-1}
REMOTE_REPO=${REMOTE_REPO:-cardano-seed-testnet}

mkdir -p "$ROOT/build/joiner"
ssh "$HOST" "cd $REMOTE_REPO/build/net-$NETWORK/testnet && tar c config.json *-genesis.json" \
  | tar x -C "$ROOT/build/joiner"
echo "chain files of net-$NETWORK copied to build/joiner/ (magic $(grep -o '"networkMagic": *[0-9]*' "$ROOT/build/joiner/shelley-genesis.json" | grep -o '[0-9]*$'))"
