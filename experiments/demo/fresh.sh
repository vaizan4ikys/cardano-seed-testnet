#!/bin/bash
# From a FRESH chain to a ready demo. Runs on the MAC, drives seedvm over ssh. bash 3.2 compatible.
#
#   ./fresh.sh --dry-run     print what would be done, change nothing (safe)
#   ./fresh.sh               DESTROYS the running chain (new genesis, new keys, new registry); asks you to type "yes"
#   ./fresh.sh --yes         same without asking
#
# TESTED END TO END on 13 November 2026 (run for real with --yes: every step OK, preflight all PASS, demo passed on the new chain).
# Step 0b sets the VM clock once from the Mac while the chain is stopped (never leave internet NTP on). Each piece reuses an existing, tested script:
#   1 ./run.sh with PV=9 (new chain)          2 wait for blocks and the Conway era     3 Kupo: wipe + start
#   4 copy the contract project and the scripts to seedvm and into the container
#   5 p0-admin.sh (keys of administrator and gateways A/B, one-time funding of the administrator)
#   6 p0-aiken.sh (check, build, apply parameters)  + copy the three .plutus files into the container
#   7 p0-registry.sh (one-shot mint of the registry token; list = [A] only)   8 p1-fund.sh (wallets of A and B)
#   9 gateways.json with the NEW wallet addresses (Mac copy, then to seedvm)  10 demo.sh --step 0 (preflight)
# Not done here (the p0.sh tests 5..9: write test, node-level refusal, chain of five, revocation, guards, withdrawal).
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HERE=$ROOT/experiments/demo
DRY=0; YES=0
for a in "$@"; do case "$a" in --dry-run) DRY=1;; --yes) YES=1;; -h|--help) sed -n '2,19p' "$0"; exit 0;; *) echo "unknown option $a (try --help)"; exit 1;; esac; done
MAGIC=${MAGIC:-42}; P0_DIR=${P0_DIR:-/tmp/p0n}
SSHO="-o ConnectTimeout=10 -o ServerAliveInterval=15"
vm() { local o rc=0; o=$(ssh -n $SSHO seedvm "$@" 2>&1) || rc=$?; [ -n "$o" ] && { printf '%s\n' "$o" | grep -v -E "post-quantum|vulnerable|upgraded" || true; }; return $rc; }
step() { printf '\n######## %s\n' "$*"; }
say() { printf '%s\n' "$*"; }
# act "text" command...: dry run prints the command, real run executes it
act() { local d=$1; shift; if [ $DRY = 1 ]; then say "  WOULD: $d"; say "         $*"; else say "  $d"; "$@"; fi; }
die() { say "STOP: $*"; exit 1; }
CTR="<pool-1 container>"

step "0. checks"
F=$(df -k / | awk 'NR==2 {print int($4/1048576)}'); say "  Mac free disk: ${F} GB"; [ "${F:-0}" -ge 6 ] || die "Mac has less than 6 GB free"
if [ $DRY = 1 ]; then say "  WOULD check: ssh seedvm works; VM free disk >= 6 GB; ~/tools/aiken-1.1.24 and ~/tools/kupo-2.12.0 exist"
else
  vm true || die "cannot ssh to seedvm"
  V=$(vm "df -BG --output=avail / | tail -1 | tr -dc 0-9"); say "  VM free disk: ${V} GB"; [ "${V:-0}" -ge 6 ] || die "seedvm has less than 6 GB free"
  vm "test -x ~/tools/aiken-1.1.24/aiken-aarch64-unknown-linux-musl/aiken && test -f ~/tools/kupo-2.12.0/bin/kupo" || die "aiken or kupo binary missing on seedvm"
fi
if [ $DRY = 0 ] && [ $YES = 0 ]; then
  say; say "  This DESTROYS the running chain on seedvm (all containers of net-1, all keys in $P0_DIR, the registry, Kupo's data)."
  printf '  Type yes to continue: '; read -r ans < /dev/tty; [ "$ans" = yes ] || die "not confirmed"
fi

step "0b. stop the old chain, then set the seedvm clock to the Mac clock (the chain takes its time from the VM clock)"
# Only now, with no chain running: a clock jump under a running chain would break it. This is a one-time manual set,
# NOT internet NTP (seedvm stays the chrony time source for the other VMs; they follow it).
act "ssh seedvm: ./stop.sh" vm "cd ~/cardano-seed-testnet && ./stop.sh > /dev/null 2>&1; true"
if [ $DRY = 1 ]; then say "  WOULD: sudo date -u -s @<Mac epoch> on seedvm, then check the difference is under 5 s"
else
  vm "sudo -n date -u -s @$(date -u +%s) >/dev/null" || die "could not set the clock on seedvm (needs sudo)"
  D=$(( $(vm "date -u +%s" | tail -1) - $(date -u +%s) )); [ ${D#-} -le 5 ] || die "seedvm clock still differs by $D s"
  say "  seedvm clock set; difference to the Mac: $D s"
fi

step "1. new chain with protocol version 9 (run.sh removes the old chain first; takes several minutes)"
act "ssh seedvm: ./run.sh (output in ~/fresh-run.log on seedvm)" \
  vm "cd ~/cardano-seed-testnet && PYTHONPATH=/home/seed/seed-emulator SKIP_NTP_CHECK=1 EXPOSE=1 PV=9 ./run.sh > ~/fresh-run.log 2>&1; rc=\$?; tail -3 ~/fresh-run.log; exit \$rc" || die "run.sh failed (see ~/fresh-run.log on seedvm)"

step "2. wait for the container and for blocks (era Conway, tip advancing; up to 15 minutes)"
if [ $DRY = 1 ]; then say "  WOULD poll every 10 s: pool_container 1, then 'cardano-cli conway query tip' until era = Conway and block >= 3"
else
  ok=0; n=0
  while [ $n -lt 90 ]; do
    CTR=$(vm "cd ~/cardano-seed-testnet && source scripts/lib.sh && pool_container 1" | tail -1)
    if [ -n "$CTR" ]; then
      T=$(vm "docker exec $CTR cardano-cli conway query tip --socket-path /node.socket --testnet-magic $MAGIC 2>/dev/null")
      B=$(printf '%s' "$T" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["block"] if d.get("era")=="Conway" else 0)' 2>/dev/null)
      [ "${B:-0}" -ge 3 ] 2>/dev/null && { ok=1; break; }
    fi
    n=$((n+1)); sleep 10
  done
  [ $ok = 1 ] || die "the chain did not reach block 3 in Conway within 15 minutes (see ~/fresh-run.log on seedvm)"
  say "  container $CTR, block $B"
fi

step "3. Kupo: wipe the old database and start (rebuilds from the new chain)"
act "kupo.sh wipe" vm "cd ~/cardano-seed-testnet/experiments/pipeline && ./kupo.sh wipe" || die "kupo wipe failed"
act "kupo.sh start" vm "cd ~/cardano-seed-testnet/experiments/pipeline && ./kupo.sh start" || die "kupo start failed"

step "4. copy the contract project and the scripts to seedvm and into the container"
act "rsync contract/, pipeline/, demo/ to seedvm" bash -c "
  for d in contract pipeline demo; do rsync -a --exclude build --exclude __pycache__ --exclude 'outbox*' '$ROOT/experiments/'\$d/ seedvm:cardano-seed-testnet/experiments/\$d/ 2>&1 | grep -v -E 'post-quantum|vulnerable|upgraded'; done; true"
act "docker cp the in-container scripts (p0-*, p1-*, p1-list, p1-fund) to /tmp/p0-scripts" \
  vm "C=\$(cd ~/cardano-seed-testnet && source scripts/lib.sh && pool_container 1); cd ~/cardano-seed-testnet/experiments && docker exec \$C mkdir -p /tmp/p0-scripts && docker cp contract/in-container/. \$C:/tmp/p0-scripts/ && docker cp demo/in-container/. \$C:/tmp/p0-scripts/" || die "copy into the container failed"

run() {   # run SCRIPT [ARG]: a script from /tmp/p0-scripts inside the container
  vm "C=\$(cd ~/cardano-seed-testnet && source scripts/lib.sh && pool_container 1); docker exec -e P0_DIR=$P0_DIR \$C bash /tmp/p0-scripts/$1 $MAGIC ${2:-}"
}
step "5. administrator key, keys of gateways A and B, one-time funding of the administrator (p0-admin.sh)"
act "p0-admin.sh" run p0-admin.sh || die "p0-admin.sh failed"

step "6. Aiken: check, build, apply the parameters (p0-aiken.sh on the VM), put the .plutus files into the container"
if [ $DRY = 1 ]; then
  say "  WOULD: SEED=\$(cat $P0_DIR/seed.ref in the container), TOK=\$(cat $P0_DIR/token.hex)"
  say "         ssh seedvm: bash cardano-seed-testnet/experiments/contract/p0-aiken.sh <seed txid> <seed index> <token hex> /tmp/p0build-p0n"
  say "         docker cp registry_mint.plutus gateway_write.plutus gateway_withdraw.plutus registry.policy.aiken into $P0_DIR"
else
  C=$(vm "cd ~/cardano-seed-testnet && source scripts/lib.sh && pool_container 1" | tail -1)
  SEED=$(vm "docker exec $C cat $P0_DIR/seed.ref" | tail -1); TOK=$(vm "docker exec $C cat $P0_DIR/token.hex" | tail -1)
  [ -n "$SEED" ] && [ -n "$TOK" ] || die "no seed.ref / token.hex: step 5 failed"
  BUILD=/tmp/p0build-$(basename "$P0_DIR")
  vm "bash cardano-seed-testnet/experiments/contract/p0-aiken.sh ${SEED%#*} ${SEED#*#} $TOK $BUILD" || die "aiken step failed"
  vm "for f in registry_mint gateway_write gateway_withdraw; do docker cp $BUILD/\$f.plutus $C:$P0_DIR/\$f.plutus; done; docker cp $BUILD/registry.policy.aiken $C:$P0_DIR/registry.policy.aiken" || die "copy of the .plutus files failed"
fi

step "7. mint the registry token (one-shot policy); the list starts as [A] only (p0-registry.sh)"
act "p0-registry.sh" run p0-registry.sh || die "p0-registry.sh failed"

step "8. fund the wallets of A and B (p1-fund.sh)"
act "p1-fund.sh" run p1-fund.sh || die "p1-fund.sh failed"

step "9. gateways.json with the NEW wallet addresses (GW01 = A, GW02 = B)"
if [ $DRY = 1 ]; then say "  WOULD: read gwA.addr and gwB.addr from the container, write $ROOT/experiments/pipeline/gateways.json, rsync it to seedvm"
else
  C=$(vm "cd ~/cardano-seed-testnet && source scripts/lib.sh && pool_container 1" | tail -1)
  GA=$(vm "docker exec $C cat $P0_DIR/gwA.addr" | tail -1); GB=$(vm "docker exec $C cat $P0_DIR/gwB.addr" | tail -1)
  case "$GA$GB" in addr_test1*addr_test1*) ;; *) die "could not read the wallet addresses: '$GA' '$GB'";; esac
  python3 - "$ROOT/experiments/pipeline/gateways.json" "$GA" "$GB" <<'EOP'
import json, sys
json.dump({"GW01": sys.argv[2], "GW02": sys.argv[3]}, open(sys.argv[1], "w"), indent=2)
open(sys.argv[1], "a").write("\n")
EOP
  say "  wrote gateways.json: GW01 $GA, GW02 $GB"
  rsync -a "$ROOT/experiments/pipeline/gateways.json" seedvm:cardano-seed-testnet/experiments/pipeline/gateways.json 2>&1 | grep -v -E "post-quantum|vulnerable|upgraded"
fi

step "10. preflight of the demo (demo.sh --step 0)"
act "demo.sh --step 0 --yes" "$HERE/demo.sh" --step 0 --yes || die "preflight failed: see the FAIL lines"
say
if [ $DRY = 1 ]; then say "dry run finished: nothing was changed."; else say "Fresh chain ready. Run the demo: $HERE/demo.sh"; fi
