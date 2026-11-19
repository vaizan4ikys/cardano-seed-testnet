#!/bin/bash
# Phase 0 of the Cardano smart-contract test. Runs on the Mac and drives the chain VM (seedvm) over ssh; the test
# scripts themselves run inside pool 1's container (in-container/p0-*.sh). Does NOT start, stop or restart the chain.
# The keys of the administrator and the test gateways never leave the container and are never printed.
#
#   ./p0.sh                          run everything in order (re-runs reuse the work dir and never mint a second registry)
#   FRESH=1 ./p0.sh                  first delete the work dir (only /tmp/<name> is allowed) and start over: new keys, new registry
#   P0_DIR=/tmp/p0n ./p0.sh          work dir inside the container (default /tmp/p0)
#   OLD_REGISTRY_DIRS="/tmp/p0 /tmp/p0v" ./p0.sh   work dirs of earlier runs whose (obsolete) registry coin the guard test should try
#   MAGIC=42                         network magic (default 42)
# The VM name (POOL_HOST) and the repository folder name (REPO) come from scripts/config.sh.
#
# Steps:  0 checks   1 copy files   2 administrator key + gateway keys + one-time funding   3 Aiken check/build/apply/convert (VM)
#         4 copy scripts into the container   4b one-shot mint of the registry token   5 write test: A passes, B refused at `transaction build`
#         6 node-level refusal (build-raw + submit)   7 five chained script txs   8 revocation + restore
#         8b guards (no second registry token, old registry coins inert)   9 zero-withdrawal trigger
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

# ---- settings ----
MAGIC=${MAGIC:-42}
P0_DIR=${P0_DIR:-/tmp/p0}; export P0_DIR       # set BEFORE config.sh, whose default for P0_DIR is /tmp/p0n
. "$HERE/../../scripts/config.sh"              # POOL_HOST, REPO
POOL=$POOL_HOST                                # the ssh name of the chain VM
SCRIPTS_IN_CTR=/tmp/p0-scripts                 # where the in-container scripts are copied to
SSH_NOISE="post-quantum|vulnerable|upgraded"   # lines of the ssh client that are not output of the command

# ---- helpers ----
# vm COMMAND...: run a command on the chain VM, print its output without the ssh noise, return its exit code.
vm() {
  local out rc=0
  out=$(ssh "$POOL" "$@" 2>&1) || rc=$?
  printf '%s\n' "$out" | grep -v -E "$SSH_NOISE" || true
  return $rc
}
step() { printf '\n######## %s\n' "$*"; }
# run SCRIPT [ARG]: run one of the in-container scripts as the test (it gets the settings as environment variables).
run() {
  vm "docker exec -e P0_DIR=$P0_DIR -e FRESH=${FRESH:-} -e OLD_REGISTRY_DIRS='${OLD_REGISTRY_DIRS:-}'" \
     "$CTR bash $SCRIPTS_IN_CTR/$1 $MAGIC ${2:-}"
}

step "0. checks"
FREE=$(vm "df -BG --output=avail / | tail -1 | tr -dc 0-9")
[ "${FREE:-0}" -ge 6 ] || { echo "seedvm has only ${FREE}G free (< 6G): stop"; exit 1; }
CTR=$(vm "cd ~/$REPO && source scripts/lib.sh && pool_container 1" | tail -1)
[ -n "$CTR" ] || { echo "no pool-1 container: is the chain up?"; exit 1; }
vm "docker exec $CTR bash -c 'CARDANO_NODE_SOCKET_PATH=/node.socket cardano-cli conway query tip --testnet-magic $MAGIC'" \
  | grep -E '"(block|era|slot)"' || { echo "chain does not answer"; exit 1; }
echo "container $CTR, seedvm free ${FREE}G, work dir $P0_DIR"

step "1. copy files to the VM and into the container"
rsync -a --exclude build "$HERE/" "$POOL:$REPO/experiments/contract/" 2>&1 | { grep -v -E "$SSH_NOISE" || true; }
vm "docker exec $CTR mkdir -p $SCRIPTS_IN_CTR && docker cp $REPO/experiments/contract/in-container/. $CTR:$SCRIPTS_IN_CTR/"

step "2. administrator key (dedicated), test gateway keys, one-time funding from utxo1"
run p0-admin.sh

step "3. Aiken: check, build, apply parameters, convert (on the VM): registry_mint, gateway_write, gateway_withdraw"
SEED=$(vm "docker exec $CTR cat $P0_DIR/seed.ref"); TOK=$(vm "docker exec $CTR cat $P0_DIR/token.hex")
BUILD=/tmp/p0build-$(basename "$P0_DIR")
vm "bash $REPO/experiments/contract/p0-aiken.sh ${SEED%#*} ${SEED#*#} $TOK $BUILD"

step "4. put the three compiled scripts into the container"
vm "for f in registry_mint gateway_write gateway_withdraw; do docker cp $BUILD/\$f.plutus $CTR:$P0_DIR/\$f.plutus; done;" \
   "docker cp $BUILD/registry.policy.aiken $CTR:$P0_DIR/registry.policy.aiken"
# print the policy id of each script as cardano-cli sees it
vm "docker exec $CTR bash -c 'cd $P0_DIR; for f in registry_mint gateway_write gateway_withdraw; do" \
   "echo \$f hash \$(CARDANO_NODE_SOCKET_PATH=/node.socket cardano-cli conway transaction policyid" \
   "--script-file \$f.plutus); done'"

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
