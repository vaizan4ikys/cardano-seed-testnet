#!/bin/bash
# From a FRESH chain to a ready demo (new genesis, new keys, new registry). bash 3.2 compatible (runs on the Mac too).
# Runs on the Mac and drives the chain VM over ssh, or INSIDE the Ubuntu VM (setting CHAIN_HOST, see host.sh):
#   Mac -> VM (default on macOS): runs on the MAC and drives the VM "seedvm" over ssh (CHAIN_HOST=seedvm, or any other
#     ssh alias).
#   local (default on Linux): you are INSIDE the Ubuntu VM (for example a VM on a Windows PC). Everything runs here,
#     nothing is copied, no ssh, no clock setting. The repository must be in ~/cardano-seed-testnet; install the tools
#     first with install.sh.
#     Forcing a mode: CHAIN_HOST=local ./fresh.sh   or   CHAIN_HOST=seedvm ./fresh.sh
# Other settings (environment):
#   SEED_EMULATOR       folder of seed-emulator on the chain host (default ~/seed-emulator)
#   AIKEN / KUPO_BIN    paths of the programs on the chain host (default ~/tools/..., see scripts/tools.sh)
#   SKIP_NTP_CHECK=1    local mode: start the chain although the clock is not NTP-synchronized (only if it is right)
#   EXPOSE=1            local mode: let other machines join through pool 1 (for experiments/multisite; asks for sudo)
#   MAGIC (42), P0_DIR (/tmp/p0n)
#   PROGRESS_EVERY=20   seconds between two progress lines while a long step runs (steps 1 and 2)
#
#   ./fresh.sh --dry-run     print what would be done, change nothing (safe)
#   ./fresh.sh               DESTROYS the running chain (new genesis, new keys, new registry); asks you to type "yes"
#   ./fresh.sh --yes         same without asking
#   ./fresh.sh --from N      RESUME at step N (2 to 10) after a failure, on the chain that is already running: the chain
#                            is not stopped and not rebuilt, the keys and the registry are kept, nothing is asked.
#                            When a step fails, the STOP message tells you the exact command ("resume with: ...").
#                            Use the same environment settings (CHAIN_HOST, P0_DIR ...) as in the failed run.
#                            Allowed: 2 to 10 (and only these), because each of them can be repeated safely:
#                              2   only waits for the blocks
#                              3   Kupo: wipe + start (it rebuilds its data from the chain)
#                              4   only copies files
#                              5   p0-admin.sh keeps existing keys; it takes over an earlier funding of the admin
#                              6   same seed coin -> same .plutus files
#                              7   p0-registry.sh does nothing if the registry exists (it also takes over a mint that an
#                                  earlier run sent but did not finish)
#                              8   p1-fund.sh does nothing if the gateways are funded (it also takes over an earlier
#                                  funding)
#                              9   rewrites gateways.json from the wallet files
#                              10  only checks
#                            --from 1 is the same as no --from (a new chain; it asks first). 0 and 11+ are refused.
#                            After you changed an in-container script, resume at 4 or lower (step 4 copies them).
#                            --dry-run works with --from (it lists only the steps from N on).
#   Each transaction step (5, 7, 8) waits until its transaction is in a block AND one more block is on top, and sends
#   the same signed transaction again when it gets lost (on this chain about 6 % of the forged blocks are replaced by another one).
#   Run for real on 20 November 2026 (Ubuntu 20.04 arm64 VM, local mode): --yes (every step OK, preflight all PASS) and
#   --from 4 --yes on the running chain (steps 5, 7 and 8 found their earlier work and sent nothing). Not run in Mac -> VM mode.
#
# Mac -> seedvm mode TESTED END TO END on 13 November 2026 (run for real with --yes: every step OK, preflight all PASS).
# Local mode was run for real on 19 November 2026 on an Ubuntu 20.04 arm64 VM as a new user (every step OK, preflight
# all PASS; not run on amd64); the steps are the same, only vm() runs the commands locally.
# Step 0b: in Mac -> VM mode it sets the VM clock once from the Mac while the chain is stopped (never leave internet NTP
# on); in local mode it only checks that the clock is NTP-synchronized. Each piece reuses an existing, tested script:
#   1 ./run.sh with PV=9 (new chain)          2 wait for blocks and the Conway era     3 Kupo: wipe + start
#   4 copy the contract project and the scripts to the VM (Mac mode only) and into the container
#   5 p0-admin.sh (keys of administrator and gateways A/B, one-time funding of the administrator)
#   6 p0-aiken.sh (check, build, apply parameters)  + copy the three .plutus files into the container
#   7 p0-registry.sh (one-shot mint of the registry token; list = [A] only)   8 p1-fund.sh (wallets of A and B)
#   9 gateways.json with the NEW wallet addresses (written in the repo, copied to the VM in Mac mode)
#   10 demo.sh --step 0 (preflight)
# Not done here (the p0.sh tests 5..9: write test, node-level refusal, chain of five, revocation, guards, withdrawal).
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HERE=$ROOT/experiments/demo
. "$ROOT/scripts/config.sh"     # REPO, P0_DIR (lab settings)

DRY=0; YES=0
START=1                             # the first step to run (--from N); 1 = everything, a new chain
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1;;
    --yes) YES=1;;
    --from)
      [ $# -ge 2 ] || { echo "--from needs a step number (2 to 10, try --help)"; exit 1; }
      shift; START=$1;;
    --from=*) START=${1#--from=};;
    -h|--help) sed -n '2,/^set -u$/p' "$0" | sed '$d'; exit 0;;
    *) echo "unknown option $1 (try --help)"; exit 1;;
  esac
  shift
done
# Only steps 2 to 10 can be repeated without a new chain (see the header); step 1 builds the chain, so a restart at
# step 1 is the normal run without --from.
case "$START" in
  1) ;;
  [2-9]|10) ;;
  *) echo "--from $START: only the steps 2 to 10 can be resumed (try --help)."
     echo "Step 1 builds the chain: for that run without --from."
     exit 1;;
esac

# ======================================================================================================
# Settings
# ======================================================================================================
MAGIC=${MAGIC:-42}                  # network magic of net 1 (scripts/lib.sh would give 41 + NET)
                                    # P0_DIR (work folder inside pool 1's container) comes from scripts/config.sh
SCRIPTS_IN_CTR=/tmp/p0-scripts      # where the contract scripts are copied inside the pool-1 container
SSHO="-o ConnectTimeout=10 -o ServerAliveInterval=15"
PROGRESS_EVERY=${PROGRESS_EVERY:-20}   # a long step prints "... 1 min 20 s: <what it does>" this often
. "$HERE/host.sh"       # CHAIN_HOST, LOCAL, vm(), push(), SEEDPATH
export CHAIN_HOST
if [ $LOCAL = 1 ]; then HLBL="this machine"; else HLBL=$CHAIN_HOST; fi   # how messages call the chain host

# The environment of run.sh: our lab VMs use a private time source and expose pool 1 to other machines;
# on your own VM the clock must be NTP-synchronized (SKIP_NTP_CHECK from your environment) and nothing is exposed,
# unless you start it with EXPOSE=1 (needed for the optional 3-site demo in experiments/multisite; asks for sudo once).
if [ $LOCAL = 1 ]; then RUNENV="EXPOSE=${EXPOSE:-0}"; else RUNENV="SKIP_NTP_CHECK=1 EXPOSE=1"; fi

# A shell snippet that the chain host evaluates: it prints the name of pool 1's container.
POOL_CONTAINER_CMD="cd ~/$REPO && source scripts/lib.sh && pool_container 1"

CTR="<pool-1 container>"            # replaced by the real name in step 2

# ======================================================================================================
# Helpers
# ======================================================================================================
CUR_STEP=0                          # the number of the step that is running ("0", "0b", "1" ... "10"), for die
step() { CUR_STEP=${1%%.*}; printf '\n######## %s\n' "$*"; }
say() { printf '%s\n' "$*"; }
# act "text" command...: a dry run prints the command, a real run executes it
act() {
  local text=$1; shift
  if [ $DRY = 1 ]; then
    say "  WOULD: $text"; say "         $*"
  else
    say "  $text"; "$@"
  fi
}
# die TEXT: print the reason, say how to go on (a step from 2 on can be resumed without a new chain), and stop
die() {
  say "STOP: $*"
  case "$CUR_STEP" in
    [2-9]|10)
      say "      Fix the problem, then resume at this step (the chain stays as it is; same environment settings):"
      say "      resume with: $0 --from $CUR_STEP --yes";;
    1)
      say "      Step 1 builds the chain: fix the problem and run the whole script again: $0 --yes";;
  esac
  exit 1
}
# minsec SECONDS: prints for example "2 min 05 s"
minsec() { printf '%d min %02d s' $(($1 / 60)) $(($1 % 60)); }

# with_progress HOSTLOG COMMAND...: run COMMAND in the background and print a progress line every PROGRESS_EVERY
# seconds: the time so far, the current phase (the last ">>> ..." line that run.sh wrote into HOSTLOG on the chain
# host) and the last line of HOSTLOG. Why: the first run on a new VM downloads and builds the docker images for
# 15-30 minutes without any other output. At the end it prints COMMAND's own output and returns its exit code.
with_progress() {
  local hostlog=$1 outfile pid exit_code=0 seconds=0 phase last_line
  shift
  outfile=$(mktemp "${TMPDIR:-/tmp}/fresh-step.XXXXXX")
  "$@" > "$outfile" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2> /dev/null; do
    sleep 1
    seconds=$((seconds + 1))
    # a progress line only every PROGRESS_EVERY seconds
    if [ $((seconds % PROGRESS_EVERY)) != 0 ]; then continue; fi
    phase=$(vm "grep '^>>> ' $hostlog 2> /dev/null | tail -n 1" | cut -c5-100)
    last_line=$(vm "tail -n 1 $hostlog 2> /dev/null" | tr -d '\r' | cut -c1-100)
    # when the last line IS the phase line, do not show it twice
    if [ "$last_line" = ">>> $phase" ]; then last_line=""; fi
    say "  ... $(minsec $seconds): ${phase:-starting}${last_line:+   | last line: $last_line}"
  done
  wait "$pid" || exit_code=$?
  cat "$outfile"
  rm -f "$outfile"
  say "  (took $(minsec $seconds))"
  return $exit_code
}

# The name of pool 1's container on the chain host (empty when it is not running).
find_container() { vm "$POOL_CONTAINER_CMD" | tail -1; }

# run SCRIPT [ARG]: run a script from /tmp/p0-scripts inside the container (as p0-admin.sh, p0-registry.sh ...)
run() {
  vm "C=\$($POOL_CONTAINER_CMD); docker exec -e P0_DIR=$P0_DIR \$C bash $SCRIPTS_IN_CTR/$1 $MAGIC ${2:-}"
}

# Mac mode: rsync the three experiment folders and tools.sh to the VM.
copy_to_host() {
  local d
  for d in contract pipeline demo; do
    push "$ROOT/experiments/$d/" "$REPO/experiments/$d/" --exclude build --exclude __pycache__ --exclude 'outbox*'
  done
  push "$ROOT/scripts/tools.sh" $REPO/scripts/tools.sh
}

say "chain host: $HLBL$([ $LOCAL = 1 ] && echo ' (local mode: everything runs here)')"

# ======================================================================================================
step "0. checks"
# ======================================================================================================
if [ $LOCAL = 0 ]; then
  free_gb=$(df -k / | awk 'NR==2 {print int($4/1048576)}')
  say "  Mac free disk: ${free_gb} GB"
  [ "${free_gb:-0}" -ge 6 ] || die "Mac has less than 6 GB free"
fi
if [ $DRY = 1 ]; then
  if [ $LOCAL = 1 ]; then
    say "  WOULD check: the repository is in ~/$REPO; free disk >= 6 GB"
  else
    say "  WOULD check: ssh $CHAIN_HOST works; VM free disk >= 6 GB"
  fi
  say "  WOULD check: docker works for this user; seed-emulator importable (PYTHONPATH=$SEEDPATH," \
      "Python of ~/seed-venv if it exists); the CPU type (uname -m)"
  say "  WOULD check: Aiken ~/tools/aiken-1.1.24/aiken-<aarch64|x86_64>-unknown-linux-musl/aiken (or \$AIKEN)" \
      "and ~/tools/kupo-2.12.0/bin/kupo (or \$KUPO_BIN) exist"
else
  if [ $LOCAL = 1 ]; then
    local_repo_ok "$ROOT" || die "the repository must be in ~/$REPO, but this one is in $ROOT
        hint: git clone https://github.com/vaizan4ikys/cardano-seed-testnet ~/$REPO   or   ln -s $ROOT ~/$REPO"
  else
    vm true || die "cannot ssh to $CHAIN_HOST"
    push "$ROOT/scripts/tools.sh" $REPO/scripts/tools.sh       # tools.sh must be on the VM before it is used
  fi
  vm_free_gb=$(vm "df -BG --output=avail / | tail -1 | tr -dc 0-9")
  say "  free disk on $HLBL: ${vm_free_gb} GB"
  [ "${vm_free_gb:-0}" -ge 6 ] || die "$HLBL has less than 6 GB free"
  vm "docker info > /dev/null 2>&1" || die "docker does not work for the user on $HLBL
        hint: sudo usermod -aG docker \$USER, then log out and in again (or reboot);" \
      "is the docker service running? sudo systemctl enable --now docker"
  vm "PYTHONPATH=$SEEDPATH $SEEDPY -c 'import seedemu'" || die "seed-emulator cannot be imported on $HLBL
        hint: run ~/$REPO/install.sh --check on $HLBL" \
      "(it says what is missing: the clone of seed-emulator, or ~/seed-venv)"
  vm "cd ~/$REPO && . scripts/tools.sh && [ \"\$TOOLS_ARCH\" != unknown ]" \
    || die "unknown CPU type on $HLBL (uname -m must be aarch64/arm64 or x86_64/amd64)"
  vm "cd ~/$REPO && . scripts/tools.sh && test -x \"\$AIKEN\" && test -f \"\$KUPO_BIN\"" \
    || die "aiken or kupo binary missing on $HLBL
        hint: run ~/$REPO/install.sh on $HLBL (or set AIKEN / KUPO_BIN)"
fi
if [ $DRY = 0 ] && [ $START -ge 3 ]; then
  # a resume needs the running chain: steps 3 and later work with pool 1's container
  [ -n "$(find_container)" ] || die "pool 1's container is not running on $HLBL, so there is no chain to resume on:
        run the whole script (without --from) to build a new chain"
fi
if [ $DRY = 0 ] && [ $YES = 0 ] && [ $START = 1 ]; then
  say
  say "  This DESTROYS the running chain on $HLBL (all containers of net-1, all keys in $P0_DIR," \
      "the registry, Kupo's data)."
  printf '  Type yes to continue: '; read -r answer < /dev/tty; [ "$answer" = yes ] || die "not confirmed"
fi

# ======================================================================================================
if [ $START -gt 1 ]; then
  # a resume (--from N) must NOT stop the chain, set the clock or rebuild anything
  say
  say "  resuming at step $START: the running chain is not stopped, the steps before $START are skipped"
else
  if [ $LOCAL = 1 ]; then
    step "0b. stop the old chain, check that the clock is NTP-synchronized (the chain takes its time from the VM clock)"
  else
    step "0b. stop the old chain, then set the $CHAIN_HOST clock to the Mac clock (the chain takes its time from it)"
  fi
  # The clock is set only now, with no chain running: a clock jump under a running chain would break it.
  # In Mac mode this is a one-time manual set, NOT internet NTP (seedvm stays the chrony time source for the other
  # VMs; they follow it).
  act "$HLBL: ./stop.sh" vm "cd ~/$REPO && ./stop.sh > /dev/null 2>&1; true"
  if [ $LOCAL = 1 ]; then
    if [ $DRY = 1 ]; then
      say "  WOULD: timedatectl show -p NTPSynchronized --value (a warning, not a stop, when it is not yes)"
    else
      ntp_state=$(vm "timedatectl show -p NTPSynchronized --value" | tail -1)
      if [ "$ntp_state" = yes ]; then
        say "  clock is NTP-synchronized"
      else
        say "  WARNING: the clock is not NTP-synchronized (timedatectl says '${ntp_state:-?}')." \
            "run.sh will stop with 'clock is not NTP-synced yet'."
        say "           Fix: sudo timedatectl set-ntp true, wait a minute," \
            "and check the clock of the Windows PC (VM time follows it)."
        say "           Only if you know the clock is right: SKIP_NTP_CHECK=1 $0"
      fi
    fi
  elif [ $DRY = 1 ]; then
    say "  WOULD: sudo date -u -s @<Mac epoch> on $CHAIN_HOST, then check the difference is under 5 s"
  else
    vm "sudo -n date -u -s @$(date -u +%s) >/dev/null" || die "could not set the clock on $CHAIN_HOST (needs sudo)"
    clock_diff=$(( $(vm "date -u +%s" | tail -1) - $(date -u +%s) ))
    [ ${clock_diff#-} -le 5 ] || die "$CHAIN_HOST clock still differs by $clock_diff s"
    say "  $CHAIN_HOST clock set; difference to the Mac: $clock_diff s"
  fi
fi

# ======================================================================================================
if [ $START -le 1 ]; then
  step "1. new chain with protocol version 9 (run.sh removes the old chain first; takes several minutes)"
  RUN_SH_CMD="cd ~/$REPO && PYTHONPATH=$SEEDPATH $RUNENV PV=9 ./run.sh > ~/fresh-run.log 2>&1;"
  RUN_SH_CMD="$RUN_SH_CMD rc=\$?; tail -3 ~/fresh-run.log; exit \$rc"
  say "  The first run on a new machine downloads and builds the docker images: 15-30 minutes." \
      "Later runs: about 3 minutes."
  act "$HLBL: ./run.sh (output in ~/fresh-run.log on $HLBL)" with_progress "~/fresh-run.log" vm "$RUN_SH_CMD" \
    || die "run.sh failed (see ~/fresh-run.log on $HLBL)"
fi

# ======================================================================================================
if [ $START -le 2 ]; then
  step "2. wait for the container and for blocks (era Conway, tip advancing; up to 15 minutes)"
  if [ $DRY = 1 ]; then
    say "  WOULD poll every 10 s: pool_container 1, then 'cardano-cli conway query tip'" \
        "until era = Conway and block >= 3"
  else
    reached=0; tries=0; block=""
    while [ $tries -lt 90 ]; do
      CTR=$(find_container)
      if [ -n "$CTR" ]; then
        tip_json=$(vm "docker exec $CTR cardano-cli conway query tip --socket-path /node.socket" \
                      "--testnet-magic $MAGIC 2>/dev/null")
        block=$(printf '%s' "$tip_json" | python3 -c \
          'import sys,json; d=json.load(sys.stdin); print(d["block"] if d.get("era")=="Conway" else 0)' 2>/dev/null)
        [ "${block:-0}" -ge 3 ] 2>/dev/null && { reached=1; break; }
      fi
      tries=$((tries+1))
      # every PROGRESS_EVERY seconds (one try = 10 s) say what we are waiting for
      waited=$((tries * 10))
      if [ $((waited % PROGRESS_EVERY)) -lt 10 ]; then
        if [ -z "$CTR" ]; then now="pool 1's container is not running yet"
        elif [ -z "$block" ]; then now="container $CTR is up, its node does not answer yet"
        else now="block $block (needs block 3 in the era Conway)"; fi
        say "  ... $(minsec $waited) of at most 15 min: $now"
      fi
      sleep 10
    done
    [ $reached = 1 ] || die "the chain did not reach block 3 in Conway within 15 minutes (see ~/fresh-run.log on $HLBL)"
    say "  container $CTR, block $block"
  fi
fi

# ======================================================================================================
if [ $START -le 3 ]; then
  step "3. Kupo: wipe the old database and start (rebuilds from the new chain)"
  act "kupo.sh wipe" vm "cd ~/$REPO/experiments/pipeline && ./kupo.sh wipe" || die "kupo wipe failed"
  act "kupo.sh start" vm "cd ~/$REPO/experiments/pipeline && ./kupo.sh start" || die "kupo start failed"
fi

# ======================================================================================================
if [ $START -le 4 ]; then
  step "4. copy the contract project and the scripts to the VM and into the container"
  if [ $LOCAL = 1 ]; then
    say "  local mode: the contract project and the scripts are already in place, nothing to copy to the VM"
  else
    act "rsync contract/, pipeline/, demo/ and scripts/tools.sh to $CHAIN_HOST" copy_to_host
  fi
  COPY_CMD="C=\$($POOL_CONTAINER_CMD); cd ~/$REPO/experiments && docker exec \$C mkdir -p $SCRIPTS_IN_CTR"
  COPY_CMD="$COPY_CMD && docker cp contract/in-container/. \$C:$SCRIPTS_IN_CTR/"
  COPY_CMD="$COPY_CMD && docker cp demo/in-container/. \$C:$SCRIPTS_IN_CTR/"
  act "docker cp the in-container scripts (p0-*, p1-*, p1-list, p1-fund) to $SCRIPTS_IN_CTR" vm "$COPY_CMD" \
    || die "copy into the container failed"
fi

# ======================================================================================================
if [ $START -le 5 ]; then
  step "5. administrator key, keys of gateways A and B, one-time funding of the administrator (p0-admin.sh)"
  act "p0-admin.sh" run p0-admin.sh || die "p0-admin.sh failed"
fi

# ======================================================================================================
if [ $START -le 6 ]; then
  step "6. Aiken: check, build, apply the parameters (p0-aiken.sh on the VM), put the .plutus files into the container"
  if [ $DRY = 1 ]; then
    say "  WOULD: SEED=\$(cat $P0_DIR/seed.ref in the container), TOK=\$(cat $P0_DIR/token.hex)"
    say "         $HLBL: bash $REPO/experiments/contract/p0-aiken.sh" \
        "<seed txid> <seed index> <token hex> /tmp/p0build-p0n"
    say "         docker cp registry_mint.plutus gateway_write.plutus gateway_withdraw.plutus" \
        "registry.policy.aiken into $P0_DIR"
  else
    CTR=$(find_container)
    SEED=$(vm "docker exec $CTR cat $P0_DIR/seed.ref" | tail -1)      # the one-shot seed coin: <txid>#<index>
    TOK=$(vm "docker exec $CTR cat $P0_DIR/token.hex" | tail -1)      # the registry token name in hex
    [ -n "$SEED" ] && [ -n "$TOK" ] || die "no seed.ref / token.hex: step 5 failed"
    BUILD=/tmp/p0build-$(basename "$P0_DIR")
    vm "bash $REPO/experiments/contract/p0-aiken.sh ${SEED%#*} ${SEED#*#} $TOK $BUILD" \
      || die "aiken step failed (the first run downloads the Aiken standard library from github.com:" \
             "does $HLBL have internet?)"
    vm "for f in registry_mint gateway_write gateway_withdraw;" \
       "do docker cp $BUILD/\$f.plutus $CTR:$P0_DIR/\$f.plutus; done;" \
       "docker cp $BUILD/registry.policy.aiken $CTR:$P0_DIR/registry.policy.aiken" \
      || die "copy of the .plutus files failed"
  fi
fi

# ======================================================================================================
if [ $START -le 7 ]; then
  step "7. mint the registry token (one-shot policy); the list starts as [A] only (p0-registry.sh)"
  act "p0-registry.sh" run p0-registry.sh || die "p0-registry.sh failed"
fi

# ======================================================================================================
if [ $START -le 8 ]; then
  step "8. fund the wallets of A and B (p1-fund.sh)"
  act "p1-fund.sh" run p1-fund.sh || die "p1-fund.sh failed"
fi

# ======================================================================================================
if [ $START -le 9 ]; then
  step "9. gateways.json with the NEW wallet addresses (GW01 = A, GW02 = B)"
  if [ $DRY = 1 ]; then
    say "  WOULD: read gwA.addr and gwB.addr from the container," \
        "write $ROOT/experiments/pipeline/gateways.json$([ $LOCAL = 0 ] && echo ", copy it to $CHAIN_HOST")"
  else
    CTR=$(find_container)
    ADDR_A=$(vm "docker exec $CTR cat $P0_DIR/gwA.addr" | tail -1)
    ADDR_B=$(vm "docker exec $CTR cat $P0_DIR/gwB.addr" | tail -1)
    case "$ADDR_A$ADDR_B" in
      addr_test1*addr_test1*) ;;
      *) die "could not read the wallet addresses: '$ADDR_A' '$ADDR_B'";;
    esac
    python3 - "$ROOT/experiments/pipeline/gateways.json" "$ADDR_A" "$ADDR_B" <<'EOP'
import json, sys
json.dump({"GW01": sys.argv[2], "GW02": sys.argv[3]}, open(sys.argv[1], "w"), indent=2)
open(sys.argv[1], "a").write("\n")
EOP
    say "  wrote gateways.json: GW01 $ADDR_A, GW02 $ADDR_B"
    push "$ROOT/experiments/pipeline/gateways.json" $REPO/experiments/pipeline/gateways.json
  fi
fi

# ======================================================================================================
if [ $START -le 10 ]; then
  step "10. preflight of the demo (demo.sh --step 0)"
  act "demo.sh --step 0 --yes" "$HERE/demo.sh" --step 0 --yes || die "preflight failed: see the FAIL lines"
fi

say
if [ $DRY = 1 ]; then
  say "dry run finished: nothing was changed."
else
  say "Fresh chain ready. Run the demo: $HERE/demo.sh"
fi
