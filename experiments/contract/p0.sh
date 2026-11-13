#!/bin/bash
# Phase 0 of the Cardano smart-contract test, run from the Mac against the VM (seedvm). Does NOT start, stop or restart the chain.
#   ./p0.sh                          run everything in order (re-runs reuse the work dir and never mint a second registry)
#   FRESH=1 ./p0.sh                  first delete the work dir (only /tmp/<name> is allowed) and start over: new keys, new registry
#   P0_DIR=/tmp/p0n ./p0.sh          work dir inside the container (default /tmp/p0)
#   OLD_REGISTRY_DIRS="/tmp/p0 /tmp/p0v" ./p0.sh   work dirs of earlier runs whose (obsolete) registry coin the guard test should try
# Steps:  0 checks   1 copy files   2 administrator key + gateway keys + one-time funding   3 Aiken check/build/apply/convert (VM)
#         4 copy scripts into the container   4b one-shot mint of the registry token   5 write test: A passes, B refused at `transaction build`
#         6 node-level refusal (build-raw + submit)   7 five chained script txs   8 revocation + restore
#         8b guards (no second registry token, old registry coins inert)   9 zero-withdrawal trigger
# The keys of the administrator and the test gateways never leave the container and are never printed.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
MAGIC=${MAGIC:-42}; P0_DIR=${P0_DIR:-/tmp/p0}; export P0_DIR
vm() { local o rc=0; o=$(ssh seedvm "$@" 2>&1) || rc=$?; printf '%s\n' "$o" | grep -v -E "post-quantum|vulnerable|upgraded" || true; return $rc; }
step() { printf '\n######## %s\n' "$*"; }

step "0. checks"
FREE=$(vm "df -BG --output=avail / | tail -1 | tr -dc 0-9")
[ "${FREE:-0}" -ge 6 ] || { echo "seedvm has only ${FREE}G free (< 6G): stop"; exit 1; }
C=$(vm 'cd ~/cardano-seed-testnet && source scripts/lib.sh && pool_container 1' | tail -1)
[ -n "$C" ] || { echo "no pool-1 container: is the chain up?"; exit 1; }
vm "docker exec $C bash -c 'CARDANO_NODE_SOCKET_PATH=/node.socket cardano-cli conway query tip --testnet-magic $MAGIC'" | grep -E '"(block|era|slot)"' || { echo "chain does not answer"; exit 1; }
echo "container $C, seedvm free ${FREE}G, work dir $P0_DIR"
run() { vm "docker exec -e P0_DIR=$P0_DIR -e FRESH=${FRESH:-} -e OLD_REGISTRY_DIRS='${OLD_REGISTRY_DIRS:-}' $C bash /tmp/p0-scripts/$1 $MAGIC ${2:-}"; }

step "1. copy files to the VM and into the container"
rsync -a --exclude build "$HERE/" seedvm:cardano-seed-testnet/experiments/contract/ 2>&1 | { grep -v -E "post-quantum|vulnerable|upgraded" || true; }
vm "docker exec $C mkdir -p /tmp/p0-scripts && docker cp cardano-seed-testnet/experiments/contract/in-container/. $C:/tmp/p0-scripts/"

step "2. administrator key (dedicated), test gateway keys, one-time funding from utxo1"
run p0-admin.sh

step "3. Aiken: check, build, apply parameters, convert (on the VM): registry_mint, gateway_write, gateway_withdraw"
SEED=$(vm "docker exec $C cat $P0_DIR/seed.ref"); TOK=$(vm "docker exec $C cat $P0_DIR/token.hex")
BUILD=/tmp/p0build-$(basename "$P0_DIR")
vm "bash cardano-seed-testnet/experiments/contract/p0-aiken.sh ${SEED%#*} ${SEED#*#} $TOK $BUILD"

step "4. put the three compiled scripts into the container"
vm "for f in registry_mint gateway_write gateway_withdraw; do docker cp $BUILD/\$f.plutus $C:$P0_DIR/\$f.plutus; done; docker cp $BUILD/registry.policy.aiken $C:$P0_DIR/registry.policy.aiken"
vm "docker exec $C bash -c 'cd $P0_DIR; for f in registry_mint gateway_write gateway_withdraw; do echo \$f hash \$(CARDANO_NODE_SOCKET_PATH=/node.socket cardano-cli conway transaction policyid --script-file \$f.plutus); done'"

step "4b. mint the registry token through the one-shot policy (skipped if a live registry coin exists)"
run p0-registry.sh

step "5. write test (transaction build): gateway A passes, gateway B refused while building"
run p0-write.sh
step "6. node-level refusal and acceptance (transaction build-raw + submit)"
run p0-nodelevel.sh
step "7. five chained script transactions"
run p0-chain.sh 5
step "8. revocation and restore"
run p0-revoke.sh
step "8b. guards: no second registry token, old-policy registry coins are inert"
run p0-guards.sh
step "9. zero-withdrawal trigger (stretch)"
run p0-withdraw.sh
echo; echo "Phase 0 finished."
