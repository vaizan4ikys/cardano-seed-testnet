#!/bin/bash
# Leader demo on the private Cardano chain: sensors -> gateways -> contract -> chain -> Kupo -> web page.
# Runs on the Mac (it drives the chain VM over ssh) or INSIDE the Ubuntu VM (CHAIN_HOST=local). bash 3.2 compatible.
# Seven steps (0..6). Every check prints a PASS or FAIL line (a FAIL is followed by a "hint:" line); SUMMARY at the end.
#
# Where it runs (setting CHAIN_HOST, see host.sh):
#   Mac -> VM (default on macOS): runs on the MAC and drives the VM "seedvm" over ssh (CHAIN_HOST=seedvm, or another
#     ssh alias); the Mac looks at the page through an ssh tunnel.
#   local (default on Linux, CHAIN_HOST=local): you are INSIDE the Ubuntu VM (for example a VM on a Windows PC).
#     Nothing is copied, no tunnel; the page is at http://127.0.0.1:8088 on the VM itself.
#     To see it on another computer:
#       ssh -L 8088:127.0.0.1:8088 <user>@<vm-address>
#       (VirtualBox NAT with port forwarding: ssh -p 2222 -L 8088:127.0.0.1:8088 <user>@127.0.0.1)
#     The repository must be in ~/cardano-seed-testnet; install the tools first with install.sh.
#
# Other settings (environment; the defaults are in the settings block below):
#   SEED_EMULATOR       folder of seed-emulator on the chain host (default ~/seed-emulator)
#   PORT                page port (default 8088, from scripts/config.sh)
#   MAGIC               network magic (default 42)
#   DEMO_B, DEMO_T      gateway batch: B readings or T seconds (defaults 100, 10)
#   DEMO_SILENT         the page marks a sensor silent after this many seconds without a reading (default 40)
#   DEMO_CLOCK_STRICT   1 = a clock difference Mac/VM (more than 3 s) is a FAIL instead of a warning (default 0)
#
#   ./demo.sh                 the whole demo, a pause "press Enter" before every step
#   ./demo.sh --yes           no pauses (rehearsal: tells you with PASS/FAIL whether everything works)
#   ./demo.sh --step N        only step N (0..6); it starts what it needs and stops it again at the end
#   ./demo.sh --keep          with --step: do not stop the processes at the end (stop later with --step 6)
#   ./demo.sh --open          open http://127.0.0.1:8088 in the browser (step 1; macOS only, on Linux the address is printed)
#
# Steps: 0 preflight  1 page server (+ tunnel in Mac mode)  2 gateway GW01 (enrolled) + 10 sensors
#        3 gateway GW02 (NOT enrolled)  4 revoke GW01, then enrol again  5 one sensor goes silent  6 clean stop
# Processes on the chain host log to /tmp/demo-logs/<name>.log, outboxes are in /tmp/demo-run-<time>/ (not in the repo).
# The registry must end with A enrolled, B not enrolled (also after Ctrl-C: the cleanup repairs it).
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HERE=$ROOT/experiments/demo
. "$ROOT/scripts/config.sh"     # REPO, P0_DIR, KUPO_PORT, PAGE_PORT (lab settings)

YES=0; ONLY=""; OPEN=0; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1;;
    --open) OPEN=1;;
    --keep) KEEP=1;;
    --step) shift; ONLY=${1:-};;
    -h|--help) sed -n '2,33p' "$0"; exit 0;;
    *) echo "unknown option $1 (try --help)"; exit 1;;
  esac
  shift
done
case "$ONLY" in ""|0|1|2|3|4|5|6) ;; *) echo "--step needs a number 0..6"; exit 1;; esac

# ======================================================================================================
# Settings (override with environment variables)
# ======================================================================================================
MAGIC=${MAGIC:-42}                   # network magic of net 1 (scripts/lib.sh would give 41 + NET)
PORT=${PORT:-$PAGE_PORT}             # port of the web page on the chain host (and of the ssh tunnel on the Mac)
GWA_PORT=9101; GWB_PORT=9102         # the sensors of gateway A / B send to these ports
B=${DEMO_B:-100}; T=${DEMO_T:-10}    # gateway batch: 100 readings or 10 s
SILENT=${DEMO_SILENT:-40}            # page: a sensor is silent after this many seconds without a new reading
NA=10; NB=5                          # number of sensors of gateway A / B (1 reading per second each)

VPIPE=$REPO/experiments/pipeline     # the pipeline folder on the chain host (relative to $HOME there)
SCRIPTS_IN_CTR=/tmp/p0-scripts       # where the contract scripts are copied inside the pool-1 container
TUNNEL_PID=/tmp/demo-tunnel.pid      # Mac mode: pid of the ssh tunnel to the page
TUNNEL_LOG=/tmp/demo-tunnel.log
URL=http://127.0.0.1:$PORT
SSHO="-o ConnectTimeout=10 -o ServerAliveInterval=15"
SSHO="$SSHO -o ControlMaster=auto -o ControlPath=/tmp/demo-cm-%C -o ControlPersist=120"

CTR=""; RUN=""; KUPO_URL=""          # filled in later: pool-1 container, run directory, Kupo address

. "$HERE/host.sh"       # CHAIN_HOST, LOCAL, vm(), push(), SEEDPATH
export CHAIN_HOST
if [ $LOCAL = 1 ]; then HLBL="this machine"; else HLBL=$CHAIN_HOST; fi   # how messages call the chain host

# ======================================================================================================
# Helpers: printing and checks
# ======================================================================================================
# Run remote.sh (the process helper) on the chain host.
vmx() { vm "bash $REPO/experiments/demo/remote.sh $(printf '%q ' "$@")"; }
# Run a command inside the pool-1 container of the chain host.
ctr() { vm "docker exec -e P0_DIR=$P0_DIR $CTR $*"; }
say() { printf '%s\n' "$*"; }
hr() { printf '\n==================== %s\n' "$*"; }
# explain LINE...: the text the presenter reads aloud before a step.
explain() { printf '\n'; for l in "$@"; do printf '  %s\n' "$l"; done; printf '\n'; }
pause() { [ $YES = 1 ] && return 0; printf '  [press Enter to start this step] '; read -r _ < /dev/tty; }

# ok / bad / hint print the check lines that people and docs rely on (PASS / FAIL / hint:).
FAILS=0; NCHK=0
ok() { NCHK=$((NCHK+1)); say "  PASS  $*"; }
bad() { NCHK=$((NCHK+1)); FAILS=$((FAILS+1)); say "  FAIL  $*"; }
hint() { say "        hint: $*"; }

# ---- reading the state of the page (the JSON that the page server publishes) ----
api() { curl -s -m 5 "$URL/api/state"; }
# page_state 'python expression using s (the state)' -> prints the value (empty on error)
page_state() {
  api | python3 -c 'import sys,json; s=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1" 2>/dev/null
}
# gw_field GW01 batches -> a field of one gateway on the page
gw_field() { page_state "[g for g in s['gateways'] if g['name']=='$1'][0]['$2']"; }
# The sensors of gateway A are AGRI_001 ... AGRI_0NN: how many of the first $1 sensors are silent / live on the page.
count_silent() {
  page_state "sum(1 for x in s['sensors'] if x['sensor'] in ['AGRI_%03d'%i for i in range(1,$1+1)] and x['silent'])"
}
count_live() {
  page_state "sum(1 for x in s['sensors'] if x['sensor'] in ['AGRI_%03d'%i for i in range(1,$1+1)] and not x['silent'])"
}
is_silent() { page_state "[x['silent'] for x in s['sensors'] if x['sensor']=='$1'][0]"; }
kupo_ok() { [ "$(page_state "s['kupo']['ok']")" = True ]; }
# as_number VALUE -> VALUE if it is all digits, else 0 (the page may answer with nothing)
as_number() { case "$1" in ''|*[!0-9]*) echo 0;; *) echo "$1";; esac; }

# ---- counting lines in the logs of the demo processes (on the chain host) ----
log_count() { as_number "$(vmx count "$1" "$2")"; }                # log_count NAME REGEX
batches_sent() { log_count gw$1 '^[0-9:]* sent: '; }              # batches sent by gateway A or B (from its log)
batches_refused() { log_count gw$1 REFUSED; }                     # batches the contract refused (gateway A or B)
remote_alive() { vmx alive "$1" >/dev/null 2>&1; }                 # is the demo process NAME running?
dead_count() { as_number "$(vmx deadcount "$1" | tail -1)"; }     # batch files in the dead/ folder of an outbox

# wait_for TIMEOUT "condition (shell)" "status (shell, printed each round)"
wait_for() {
  local timeout=$1 cond=$2 status=$3 start=$SECONDS
  while :; do
    if eval "$cond"; then printf '\n'; return 0; fi
    [ $((SECONDS - start)) -ge "$timeout" ] && { printf '\n'; return 1; }
    printf '\r    [%3ds] %s   ' "$((SECONDS - start))" "$(eval "$status")"
    sleep 3
  done
}

# ======================================================================================================
# Process control (everything runs on the chain host through remote.sh)
# ======================================================================================================
# A new run directory when no demo process is running (fresh outboxes), else the current one.
ensure_run() {
  RUN=$(vmx rundir | tail -1)
  if [ -z "$RUN" ] || [ -z "$(vmx list)" ]; then RUN=$(vmx newrun | tail -1); fi
}

# The Kupo address: Kupo listens inside the pool-1 container.
find_kupo_url() {
  local ip
  ip=$(vm "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' $CTR" | awk '{print $1}')
  KUPO_URL=http://$ip:$KUPO_PORT
}

start_server() {
  vmx start server $VPIPE "python3 -u server.py --port $PORT --silent-after $SILENT --kupo $KUPO_URL" | tail -1
}

# Mac mode: the page is on the VM, so the Mac opens an ssh tunnel to it. Local mode needs none.
start_tunnel() {
  [ $LOCAL = 1 ] && return 0
  if [ -f $TUNNEL_PID ] && kill -0 "$(cat $TUNNEL_PID)" 2>/dev/null; then return 0; fi
  ssh -o ControlPath=none -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
      -N -L $PORT:127.0.0.1:$PORT $CHAIN_HOST < /dev/null > $TUNNEL_LOG 2>&1 &
  echo $! > $TUNNEL_PID
}
stop_tunnel() { [ -f $TUNNEL_PID ] && { kill "$(cat $TUNNEL_PID)" 2>/dev/null; rm -f $TUNNEL_PID; }; return 0; }

# Start the page server (and the tunnel) when the page does not answer yet; for steps 2..5 run alone.
ensure_page() { kupo_ok || start_page_quietly; }
start_page_quietly() {
  start_server
  start_tunnel
  wait_for 40 kupo_ok 'echo waiting for the page' || say "  page does not answer"
}

# start_gateway A|B   (A = GW01 on the registry list, B = GW02 not on the list)
start_gateway() {
  local g=$1 id port gw_cmd
  if [ $g = A ]; then id=GW01; port=$GWA_PORT; else id=GW02; port=$GWB_PORT; fi
  gw_cmd="env GATEWAY=$g python3 -u gateway.py --B $B --T $T --listen-port $port"
  gw_cmd="$gw_cmd --outbox $RUN/outbox$g --gateway-id $id"
  gw_cmd="$gw_cmd --submit command --submit-command './submit_contract.sh {file} {hash}' --retry 5"
  vmx start gw$g $VPIPE "$gw_cmd" | tail -1
}

# start_sensors NAME PORT COUNT [extra args]. Each call gets a new range of sequence numbers
# (epoch + 1000000 * k) so that restarted sensors never reuse a number.
SEQK=0
start_sensors() {
  local name=$1 port=$2 n=$3; shift 3
  SEQK=$((SEQK + 1))
  vmx start $name $VPIPE \
    "python3 -u sensor.py --sensors $n --interval 1 --port $port --seq-start $(( $(date +%s) + 1000000 * SEQK )) $*" \
    | tail -1
}

# ---- the registry (list of enrolled gateways) must end as it started: A enrolled, B not ----
REVOKED=0; INTERRUPTED=0; CLEANED=0
restore_registry() {
  [ -n "$CTR" ] || return 0
  local r; r=$(ctr bash $SCRIPTS_IN_CTR/p1-list.sh $MAGIC | tail -1)
  case "$r" in
    *A=not-enrolled*) say "cleanup: enrolling A again"; ctr bash $SCRIPTS_IN_CTR/p1-enroll.sh $MAGIC A | tail -1;;
  esac
  case "$r" in
    *B=enrolled*) say "cleanup: revoking B"; ctr bash $SCRIPTS_IN_CTR/p1-revoke.sh $MAGIC B | tail -1;;
  esac
  REVOKED=0
}

# Stop everything the demo started and repair the registry (runs once, at the end and on Ctrl-C).
cleanup() {
  [ $CLEANED = 1 ] && return 0
  CLEANED=1
  say; say "stopping what the demo started ..."
  [ $REVOKED = 1 ] && restore_registry
  vmx stop-all 2>/dev/null | sed 's/^/  /'
  stop_tunnel
  return 0
}
close_master() { [ $LOCAL = 1 ] && return 0; ssh $SSHO -O exit $CHAIN_HOST > /dev/null 2>&1; return 0; }
on_exit() {
  if [ $KEEP = 1 ] && [ $INTERRUPTED = 0 ]; then
    [ $REVOKED = 1 ] && restore_registry
  else
    cleanup
  fi
  close_master
}
on_int() { INTERRUPTED=1; say; say "interrupted"; cleanup; close_master; trap - EXIT; exit 130; }
trap on_exit EXIT
trap on_int INT TERM

# ======================================================================================================
# Results of the steps (for the SUMMARY)
# ======================================================================================================
RES0=-; RES1=-; RES2=-; RES3=-; RES4=-; RES5=-; RES6=-    # PASS, FAIL(n) or - (not run)
TM0=0; TM1=0; TM2=0; TM3=0; TM4=0; TM5=0; TM6=0           # seconds each step took

# begin: start counting the checks of a step.   finish N: record PASS or FAIL(n) of step N and its time.
begin() { FAILS=0; NCHK=0; S0=$SECONDS; }
finish() {
  local r=PASS
  [ $FAILS -gt 0 ] && r="FAIL($FAILS)"
  eval "RES$1=\$r; TM$1=\$((SECONDS - S0))"
  say; say "  step $1: $r, $((SECONDS - S0)) s"
}

sync_demo() { push "$HERE/" $REPO/experiments/demo/; }

# For --step N without step 0: find the container, the run directory and the Kupo address.
need_basics() {
  sync_demo
  [ -n "$CTR" ] || CTR=$(vmx ctr | tail -1)
  [ -n "$CTR" ] || { say "pool 1 container not found: is the chain up?"; exit 1; }
  [ -n "$KUPO_URL" ] || find_kupo_url
  ensure_run
}

# ======================================================================================================
# STEP 0: preflight. The checks are small functions, called in the order the audience sees the lines.
# ======================================================================================================

# Local mode: the repository must be in ~/<REPO>. Mac mode: Mac disk and ssh. Returns 1 when the demo cannot go on.
preflight_machine() {
  local free_gb
  if [ $LOCAL = 1 ]; then
    # the commands on the chain host use paths relative to $HOME
    if local_repo_ok "$ROOT"; then
      ok "repository is in ~/$REPO"
    else
      bad "the repository is in $ROOT, not in ~/$REPO"
      hint "git clone https://github.com/vaizan4ikys/cardano-seed-testnet ~/$REPO   or   ln -s $ROOT ~/$REPO"
      return 1
    fi
  else
    free_gb=$(df -k / | awk 'NR==2 {print int($4/1048576)}')
    if [ "${free_gb:-0}" -ge 6 ]; then
      ok "Mac disk free: ${free_gb} GB"
    else
      bad "Mac disk free only ${free_gb} GB (< 6)"; hint "free some space"
    fi
    if vm "true"; then
      ok "ssh to $CHAIN_HOST works"
    else
      bad "cannot ssh to $CHAIN_HOST"; hint "is the VM running? try: ssh $CHAIN_HOST"
      return 1
    fi
  fi
}

# Disk, docker and seed-emulator on the chain host. Returns 1 when docker does not work.
preflight_vm_tools() {
  local free_gb
  free_gb=$(vm "df -BG --output=avail / | tail -1 | tr -dc 0-9")
  if [ "${free_gb:-0}" -ge 6 ]; then
    ok "VM disk free: ${free_gb} GB"
  else
    bad "VM disk free only ${free_gb:-?} GB (< 6)"
    hint "clean up on $HLBL (docker system prune, old logs)"
  fi

  if vm "docker info > /dev/null 2>&1"; then
    ok "docker works for the user on $HLBL"
  else
    bad "docker does not work for the user on $HLBL"
    hint "sudo usermod -aG docker \$USER, then log out and in again; is the service running?" \
         "sudo systemctl enable --now docker"
    return 1
  fi

  if vm "PYTHONPATH=$SEEDPATH $SEEDPY -c 'import seedemu' > /dev/null 2>&1"; then
    ok "seed-emulator can be imported (python3, SEED_EMULATOR or ~/seed-emulator)"
  else
    bad "seed-emulator cannot be imported on $HLBL"
    hint "run ~/$REPO/install.sh --check on $HLBL" \
         "(it says what is missing: the clone of seed-emulator, or the Python environment ~/seed-venv)"
  fi
}

# Pool-1 container up? Sets CTR. Returns 1 when there is none.
preflight_container() {
  CTR=$(vmx ctr | tail -1)
  if [ -n "$CTR" ]; then
    ok "pool 1 container up: $CTR"
  else
    bad "pool 1 container not running"
    hint "start the chain: fresh.sh, or on $HLBL: ./run.sh"
    return 1
  fi
}

# Does the chain tip advance? Waits up to 30 s. Sets TIP1/TIP2 ("block slot syncProgress") for the clock check.
preflight_tip() {
  local i
  TIP1=$(vmx tip | tail -1); TIP2=$TIP1
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 3
    TIP2=$(vmx tip | tail -1)
    [ "${TIP2%% *}" -gt "${TIP1%% *}" ] 2>/dev/null && break
  done
  if [ -n "$TIP1" ] && [ "${TIP2%% *}" -gt "${TIP1%% *}" ] 2>/dev/null; then
    ok "chain tip advancing: block ${TIP1%% *} -> ${TIP2%% *} in $((i * 3)) s"
  else
    bad "chain tip not advancing for 30 s (${TIP1:-none} -> ${TIP2:-none})"
    hint "the chain is stalled: see README 'what to do if'; a fresh chain: fresh.sh"
  fi
}

# Kupo (the indexer): running and at most 30 slots behind the chain. Sets KUPO_URL.
preflight_kupo() {
  local status slots_behind
  find_kupo_url
  status=$(vm "cd $VPIPE && ./kupo.sh status")
  slots_behind=$(printf '%s\n' "$status" | sed -n 's/.*behind: *\(-\{0,1\}[0-9]*\) slots.*/\1/p' | tail -1)
  if [ -n "$slots_behind" ] && [ "$slots_behind" -le 30 ]; then
    ok "Kupo running and caught up (behind $slots_behind slots) at $KUPO_URL"
  else
    bad "Kupo not ok: $(printf '%s\n' "$status" | tr '\n' ' ' | cut -c1-160)"
    hint "on $HLBL: cd $VPIPE && ./kupo.sh start   (after a fresh chain: ./kupo.sh wipe first)"
  fi
}

# Clock 1: the VM clock and the chain agree (the node reports syncProgress in its tip).
preflight_clock_chain() {
  local sync_progress
  sync_progress=$(echo "$TIP2" | awk '{print $3}')
  if [ -n "$sync_progress" ] &&
     python3 -c "import sys; sys.exit(0 if float('$sync_progress') >= 99.9 else 1)" 2>/dev/null; then
    ok "VM clock agrees with the chain time (node sync progress $sync_progress %)"
  else
    bad "node sync progress is ${sync_progress:-?} % (VM clock and chain time disagree)"
    hint "the chain needs a restart after a clock jump: fresh.sh (new chain)"
  fi
}

# Clock 2 (Mac mode): the VM clock against the Mac clock. Only a warning unless DEMO_CLOCK_STRICT=1.
preflight_clock_mac() {
  local mac_before vm_time mac_after delta
  if [ $LOCAL = 1 ]; then ok "local mode: one machine, one clock"; return 0; fi
  mac_before=$(python3 -c 'import time; print(time.time())')
  vm_time=$(vm "date +%s.%N")
  mac_after=$(python3 -c 'import time; print(time.time())')
  delta=$(python3 -c "print(round($vm_time - ($mac_before + $mac_after) / 2, 1))" 2>/dev/null)
  if [ -n "$delta" ] && python3 -c "import sys; sys.exit(0 if abs($delta) < 3 else 1)"; then
    ok "VM clock differs from the Mac clock by $delta s"
  elif [ "${DEMO_CLOCK_STRICT:-0}" = 1 ]; then
    bad "VM clock differs from the Mac clock by ${delta:-?} s (> 3 s)"
    hint "on $CHAIN_HOST: sudo timedatectl set-ntp true" \
         "(this jumps the clock: the chain must be restarted afterwards)"
  else
    say "  WARN  VM clock differs from the Mac clock by ${delta:-?} s (VM minus Mac)." \
        "Not blocking: sensors, gateways, node and page all use the VM clock;"
    say "        times seen on the page are VM times. (DEMO_CLOCK_STRICT=1 makes this a FAIL.)"
  fi
}

# Copy the pipeline, contract and demo scripts to the chain host and into the container,
# then check that the scripts, the policy files and the keys are all there.
preflight_scripts_in_container() {
  local missing files
  [ $LOCAL = 1 ] || say "  (copying the pipeline, contract and demo scripts to $CHAIN_HOST and into the container)"
  push "$ROOT/experiments/pipeline/" "$VPIPE/" --exclude __pycache__ --exclude 'outbox*'
  push "$ROOT/experiments/contract/in-container/" $REPO/experiments/contract/in-container/
  push "$HERE/" $REPO/experiments/demo/
  vm "cd $REPO/experiments && docker cp contract/in-container/. $CTR:$SCRIPTS_IN_CTR/ &&" \
     "docker cp demo/in-container/p1-list.sh $CTR:$SCRIPTS_IN_CTR/p1-list.sh" > /dev/null

  files="$SCRIPTS_IN_CTR/p0-lib.sh $SCRIPTS_IN_CTR/p1-batch.sh $SCRIPTS_IN_CTR/p1-enroll.sh"
  files="$files $SCRIPTS_IN_CTR/p1-revoke.sh $SCRIPTS_IN_CTR/p1-list.sh"
  files="$files gateway_write.plutus registry.ref policy.id token.hex admin.skey gwA.skey gwB.skey"
  missing=$(ctr "bash -c 'cd $P0_DIR && for f in $files; do [ -f \$f ] || echo \$f; done'")
  if [ -z "$missing" ]; then
    ok "scripts, policy files and keys are in the container"
  else
    bad "missing in the container: $(echo $missing)"
    hint "run experiments/contract/p0.sh (or fresh.sh)"
  fi
}

# The registry list must be A enrolled, B not enrolled.
preflight_registry() {
  local r
  r=$(ctr bash $SCRIPTS_IN_CTR/p1-list.sh $MAGIC | tail -1)
  case "$r" in
    *"A=enrolled B=not-enrolled"*) ok "registry list: A enrolled, B not enrolled ($r)";;
    *)
      bad "registry list is wrong: $r"
      hint "enrol A, on $HLBL:  docker exec -e P0_DIR=$P0_DIR $CTR bash $SCRIPTS_IN_CTR/p1-enroll.sh $MAGIC A" \
           "    revoke B: same with p1-revoke.sh ... B";;
  esac
}

# gateways.json (names -> wallet addresses, read by the page) must match the real wallets of A and B.
preflight_gateways_json() {
  local addr_a addr_b
  addr_a=$(ctr cat $P0_DIR/gwA.addr); addr_b=$(ctr cat $P0_DIR/gwB.addr)
  if vm "grep -q $addr_a $VPIPE/gateways.json && grep -q $addr_b $VPIPE/gateways.json"; then
    ok "gateways.json holds the wallet addresses of A and B"
  else
    bad "gateways.json does not match the wallets of A/B (the page would show 'unknown signer')"
    hint "write {\"GW01\": \"$addr_a\", \"GW02\": \"$addr_b\"} into experiments/pipeline/gateways.json" \
         "(fresh.sh does this)"
  fi
}

# No old demo processes, and the ports of the page and of both gateways are free.
preflight_leftovers_and_ports() {
  local leftovers port_page port_a port_b
  leftovers=$(vmx leftovers)
  if [ -z "$leftovers" ]; then
    ok "no leftover demo processes on $HLBL"
  else
    bad "leftover processes: $(echo "$leftovers" | head -3 | tr '\n' ';' | cut -c1-200)"
    hint "./demo.sh --step 6 (clean stop), or kill them by hand"
  fi

  port_page=$(vmx portfree $PORT | tail -1)
  port_a=$(vmx portfree $GWA_PORT | tail -1)
  port_b=$(vmx portfree $GWB_PORT | tail -1)
  if [ "$port_page" = free ] && [ "$port_a" = free ] && [ "$port_b" = free ]; then
    ok "ports $PORT, $GWA_PORT, $GWB_PORT are free on $HLBL"
  else
    bad "a port is busy on $HLBL (page $port_page, gateway A $port_a, gateway B $port_b)"
    hint "find the owner, on $HLBL: ss -ltnp | grep -E \"$PORT|$GWA_PORT|$GWB_PORT\" ;" \
         "set another page port with PORT=8089 ./demo.sh"
  fi

  # Mac mode: the tunnel port on the Mac must be free as well (local mode: the check above looked at this machine)
  if [ $LOCAL = 1 ]; then
    :
  elif (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && [ ! -f $TUNNEL_PID ]; then
    bad "port $PORT is busy on the Mac (an old tunnel?)"
    hint "lsof -i :$PORT ; kill the old ssh -L"
  else
    ok "port $PORT is free on the Mac"
  fi
}

# What the audience sees: a list of PASS lines. On a FAIL the demo stops and the hint says what to do.
step0() {
  hr "STEP 0: preflight (is everything ready?)"
  explain "We check the chain, the indexer (Kupo), the clocks, the disk, the scripts in the container and the registry list." \
          "Look for: only PASS lines. On a FAIL the demo stops and says what to do."
  pause; begin

  preflight_machine || { finish 0; return 1; }
  preflight_vm_tools || { finish 0; return 1; }
  sync_demo
  preflight_container || { finish 0; return 1; }
  preflight_tip
  preflight_kupo
  preflight_clock_chain
  preflight_clock_mac
  preflight_scripts_in_container
  preflight_registry
  preflight_gateways_json
  preflight_leftovers_and_ports
  finish 0
  [ $FAILS -eq 0 ]
}

# ======================================================================================================
# STEP 1: the page server (and the tunnel)
# ======================================================================================================
# What the audience sees: the page opens in the browser, shows the chain tip moving and Kupo "ok".
step1() {
  if [ $LOCAL = 1 ]; then
    hr "STEP 1: start the page server on this machine"
  else
    hr "STEP 1: start the page server on $CHAIN_HOST and the ssh tunnel"
  fi
  explain "The page server reads the chain through Kupo (it keeps nothing of its own) and shows sensors, batches and gateways." \
          "Look for: the page opens at $URL; it shows the chain tip moving and Kupo 'ok'." \
          "Old sensor values from earlier runs may be on it: they go 'silent' after $SILENT s, that is normal."
  pause; begin
  need_basics; ensure_run
  say "  $(start_server)"
  start_tunnel

  local via_tunnel="" tunnel_log_hint="" tip_block
  [ $LOCAL = 0 ] && via_tunnel=' through the tunnel'
  [ $LOCAL = 0 ] && tunnel_log_hint=', /tmp/demo-tunnel.log on the Mac'
  if wait_for 40 kupo_ok 'echo waiting for the page'; then
    ok "page answers$via_tunnel; Kupo ok"
  else
    bad "page did not answer at $URL within 40 s"
    hint "see /tmp/demo-logs/server.log on $HLBL$tunnel_log_hint; port busy: PORT=8089 ./demo.sh"
  fi
  tip_block=$(page_state "s['tip']['block']")
  [ -n "$tip_block" ] && ok "page shows the chain tip: block $tip_block" || bad "page has no tip"

  say "  run directory on $HLBL: $RUN"
  say "  >>> open $URL in the browser <<<"
  [ $LOCAL = 1 ] && say "  (another computer: ssh -L $PORT:127.0.0.1:$PORT <user>@<vm-address>;" \
                        "VirtualBox NAT with port forwarding: ssh -p 2222 -L $PORT:127.0.0.1:$PORT <user>@127.0.0.1)"
  if [ $OPEN = 1 ]; then
    if [ "$(uname -s)" = Darwin ]; then open "$URL"
    else say "  (--open opens a browser on macOS only; open the address by hand)"; fi
  fi
  finish 1
  [ $FAILS -eq 0 ]
}

# ======================================================================================================
# STEP 2: gateway A (enrolled) with 10 sensors
# ======================================================================================================
# What the audience sees: batches appear on the page, the depth bar grows, GW01's receipts counter rises.
step2() {
  hr "STEP 2: gateway GW01 (enrolled) and $NA sensors"
  explain "Gateway A (shown as GW01) is on the registry list. $NA sensors send 1 reading per second each." \
          "The gateway makes a batch every $T s, signs one transaction with its own key and the contract lets it in." \
          "Look at the page: batches appearing in the list, the depth bar of each batch growing as blocks are added," \
          "the 'receipts' counter of GW01 rising by one per batch, the sensor values and charts moving."
  pause; begin
  need_basics; ensure_page
  say "  $(start_gateway A)"
  say "  $(start_sensors sensorsA $GWA_PORT $NA)"

  local batches_before
  batches_before=$(as_number "$(gw_field GW01 batches)")
  say "  waiting for 3 batches to be sent and to show up on the page (about 40 s) ..."
  wait_for 150 \
    '[ "$(batches_sent A)" -ge 3 ] && [ "$(as_number "$(gw_field GW01 batches)")" -ge $((batches_before + 3)) ]' \
    'echo "sent=$(batches_sent A) page batches=$(gw_field GW01 batches) receipts=$(gw_field GW01 receipts)"'

  local sent page_batches receipts dead depth live
  sent=$(batches_sent A)
  page_batches=$(as_number "$(gw_field GW01 batches)")
  receipts=$(gw_field GW01 receipts)
  dead=$(dead_count $RUN/outboxA)
  [ "$sent" -ge 3 ] && ok "gateway A sent $sent batches (log)" || bad "gateway A sent only $sent batches"
  if [ "$page_batches" -ge $((batches_before + 3)) ]; then
    ok "page shows $page_batches batches of GW01 (was $batches_before), receipts counter = $receipts"
  else
    bad "page shows only $page_batches batches of GW01 (was $batches_before)"
    hint "Kupo behind? ./demo.sh --step 0; gateway log: /tmp/demo-logs/gwA.log"
  fi
  depth=$(as_number "$(page_state "([b['depth'] for b in s['batches'] if b['signer_name']=='GW01'] + [0])[0] or 0")")
  if [ "$depth" -ge 1 ]; then
    ok "depth bar: the newest batch of GW01 is $depth blocks deep (it grows with every block)"
  else
    bad "the newest batch of GW01 has no depth yet"
  fi
  [ "$(as_number "$receipts")" -ge 3 ] && ok "receipts counter of GW01 is $receipts" \
    || bad "receipts counter of GW01 is '$receipts' (expected >= 3)"
  [ "$dead" -eq 0 ] && ok "no dead-letter batches of A" || bad "$dead dead-letter batches of A"
  live=$(as_number "$(count_live $NA)")
  if [ "$live" -ge $((NA - 1)) ]; then
    ok "$live of $NA sensors are live on the page"
  else
    bad "only $live of $NA sensors live on the page"
    hint "readings arrive in batches every ~$T s; wait or raise DEMO_SILENT"
  fi
  say "  last gateway lines:"; vmx lines gwA '^[0-9:]* (batch|sent)' 4 | sed 's/^/    /'
  finish 2
  [ $FAILS -eq 0 ]
}

# ======================================================================================================
# STEP 3: gateway B (NOT enrolled) is refused by the contract
# ======================================================================================================
# What the audience sees: REFUSED lines, dead/ filling up, GW02 stays at 0 batches on the page.
step3() {
  hr "STEP 3: gateway GW02 (NOT enrolled) with 5 sensors"
  explain "Gateway B (GW02) has its own funded wallet and its own key, but it is not on the registry list." \
          "It builds the same kind of transaction. The contract (checked by the node when the transaction is submitted)" \
          "refuses it: no batch of GW02 is ever written to the chain. The gateway moves the batch to dead/ and goes on." \
          "Look for: the REFUSED line below, 'dead/' filling up, and on the page GW02 stays at 0 batches."
  pause; begin
  need_basics; ensure_page
  say "  $(start_gateway B)"
  say "  $(start_sensors sensorsB $GWB_PORT $NB)"
  say "  waiting for 2 refused batches (about 35 s) ..."
  wait_for 120 '[ "$(batches_refused B)" -ge 2 ]' 'echo "refused=$(batches_refused B) dead=$(dead_count $RUN/outboxB)"'

  local refused dead sent page_batches
  refused=$(batches_refused B); dead=$(dead_count $RUN/outboxB); sent=$(batches_sent B)
  if [ "$refused" -ge 2 ]; then
    ok "gateway B: $refused batches REFUSED by the contract"
  else
    bad "gateway B: only $refused refused"; hint "gateway log: /tmp/demo-logs/gwB.log"
  fi
  [ "$dead" -ge 2 ] && ok "$dead batch files moved to dead/ (not on the chain)" || bad "only $dead files in dead/"
  [ "$sent" -eq 0 ] && ok "gateway B sent nothing" || bad "gateway B reports $sent batches sent!"
  sleep 6
  page_batches=$(as_number "$(gw_field GW02 batches)")
  [ "$page_batches" -eq 0 ] && ok "page shows 0 batches from GW02" || bad "page shows $page_batches batches from GW02!"

  say "  the refusal, one line from the gateway log:"; vmx lines gwB 'REFUSED' 1 | sed 's/^/    /'
  say "  the batch moved to dead/:"; vm "ls $RUN/outboxB/dead | head -2" | sed 's/^/    /'
  vmx stop gwB | sed 's/^/  /'; vmx stop sensorsB | sed 's/^/  /'
  finish 3
  [ $FAILS -eq 0 ]
}

# ======================================================================================================
# STEP 4: revoke gateway A while its sensors keep sending, then enrol it again
# ======================================================================================================
# What the audience sees: REFUSED lines, A's sensors turn silent on the page; after the enrol they wake up.
step4() {
  hr "STEP 4: revoke GW01 while its sensors keep sending, then enrol it again"
  explain "The administrator (a dedicated key, not the key of any gateway) replaces the registry coin with a new list without A." \
          "A's sensors keep sending. A's next batches are refused (dead-letter) and the readings are lost." \
          "Look for: the REFUSED lines; on the page the sensors turn 'silent' after $SILENT s without new data." \
          "Then we enrol A again: new batches flow, the sensors on the page wake up. (The refused readings stay lost.)"
  pause; begin
  need_basics; ensure_page
  remote_alive gwA || say "  $(start_gateway A)"
  remote_alive sensorsA || say "  $(start_sensors sensorsA $GWA_PORT $NA)"
  # make sure A is flowing first
  wait_for 90 '[ "$(as_number "$(count_live $NA)")" -ge $((NA - 1)) ]' \
    'echo "live sensors=$(count_live $NA)"' >/dev/null

  local sent_before refused_before page_batches_before
  sent_before=$(batches_sent A); refused_before=$(batches_refused A)
  page_batches_before=$(as_number "$(gw_field GW01 batches)")
  say "  before: A sent $sent_before batches, page shows $page_batches_before batches," \
      "$(count_live $NA) of $NA sensors live"

  # -- revoke A (the administrator spends the registry coin into a new list without A) --
  say "  revoking A ..."; REVOKED=1
  local revoke_out; revoke_out=$(ctr bash $SCRIPTS_IN_CTR/p1-revoke.sh $MAGIC A | tail -1); say "    $revoke_out"
  case "$revoke_out" in
    OK:*"list size now 0"*) ok "registry: A revoked ($(echo "$revoke_out" | sed 's/.*took/took/'))";;
    *) bad "revoke failed: $revoke_out";;
  esac

  say "  waiting for 2 refused batches of A ..."
  wait_for 120 '[ "$(batches_refused A)" -ge $((refused_before + 2)) ]' \
    'echo "new refused=$(( $(batches_refused A) - refused_before ))"'
  local refused_now; refused_now=$(batches_refused A)
  if [ "$refused_now" -ge $((refused_before + 2)) ]; then
    ok "A's batches are refused after the revoke ($((refused_now - refused_before)) REFUSED lines)"
  else
    bad "A is not refused after the revoke"
  fi
  say "  one refusal:"; vmx lines gwA REFUSED 50 | tail -1 | sed 's/^/    /'

  say "  waiting for the page to show A's sensors silent (silent after $SILENT s) ..."
  wait_for 150 '[ "$(as_number "$(count_silent $NA)")" -ge $((NA - 1)) ]' \
    'echo "silent sensors=$(count_silent $NA) of $NA"'
  local silent; silent=$(as_number "$(count_silent $NA)")
  if [ "$silent" -ge $((NA - 1)) ]; then
    ok "page: $silent of $NA sensors silent"
  else
    bad "page: only $silent of $NA sensors silent"
  fi

  # -- enrol A again --
  say "  enrolling A again ..."
  local enrol_out; enrol_out=$(ctr bash $SCRIPTS_IN_CTR/p1-enroll.sh $MAGIC A | tail -1); say "    $enrol_out"
  case "$enrol_out" in
    OK:*"list size now 1"*) ok "registry: A enrolled again ($(echo "$enrol_out" | sed 's/.*took/took/'))"; REVOKED=0;;
    *) bad "enrol failed: $enrol_out";;
  esac

  local sent_at_enrol; sent_at_enrol=$(batches_sent A)
  say "  waiting for new batches of A to flow and the sensors to wake up ..."
  wait_for 150 \
    '[ "$(batches_sent A)" -ge $((sent_at_enrol + 2)) ] && [ "$(as_number "$(count_live $NA)")" -ge $((NA - 1)) ]' \
    'echo "new sent=$(( $(batches_sent A) - sent_at_enrol )) live sensors=$(count_live $NA)"'
  local sent_after live page_batches_after
  sent_after=$(batches_sent A)
  live=$(as_number "$(count_live $NA)")
  page_batches_after=$(as_number "$(gw_field GW01 batches)")
  if [ "$sent_after" -ge $((sent_at_enrol + 2)) ]; then
    ok "after re-enrol: $((sent_after - sent_at_enrol)) new batches sent"
  else
    bad "no new batches after re-enrol"
  fi
  if [ "$live" -ge $((NA - 1)) ]; then
    ok "page: $live of $NA sensors live again, GW01 batches $page_batches_before -> $page_batches_after"
  else
    bad "page: only $live sensors live again"
  fi
  [ "$REVOKED" = 0 ] || restore_registry
  finish 4
  [ $FAILS -eq 0 ]
}

# ======================================================================================================
# STEP 5: one sensor goes silent
# ======================================================================================================
# What the audience sees: after $SILENT s without a reading the page marks AGRI_003 "silent" (the alarm).
step5() {
  hr "STEP 5: one sensor goes silent (AGRI_003)"
  explain "We restart the sensors of GW01; sensor AGRI_003 stops sending 20 s after the start, the other nine go on." \
          "Look for: after $SILENT s without a new reading from the chain the page marks AGRI_003 'silent' (the alarm)," \
          "the other sensors keep updating. Silence is measured on the server clock, not on the sensor clock."
  pause; begin
  need_basics; ensure_page
  remote_alive gwA || say "  $(start_gateway A)"
  vmx stop sensorsA 2>/dev/null | sed 's/^/  /'
  say "  $(start_sensors sensorsA $GWA_PORT $NA --silent-sensor AGRI_003 --silent-after 20)"
  say "  waiting for the silent alarm (about 20 s + batch time + $SILENT s) ..."
  wait_for 200 '[ "$(is_silent AGRI_003)" = True ]' \
    'echo "AGRI_003 silent=$(is_silent AGRI_003) live sensors=$(count_live $NA)"'

  local agri3_silent live silent
  agri3_silent=$(is_silent AGRI_003); live=$(as_number "$(count_live $NA)"); silent=$(as_number "$(count_silent $NA)")
  [ "$agri3_silent" = True ] && ok "page: AGRI_003 is silent (alarm)" || bad "page: AGRI_003 is not silent"
  if [ "$live" -ge $((NA - 2)) ] && [ "$silent" -le 2 ]; then
    ok "the other sensors are not silent ($live live, $silent silent)"
  else
    bad "too many silent sensors: $silent silent, $live live"
  fi
  finish 5
  [ $FAILS -eq 0 ]
}

# ======================================================================================================
# STEP 6: clean stop
# ======================================================================================================
# What the audience sees: everything stops; the registry is back to "A enrolled, B not enrolled".
step6() {
  hr "STEP 6: clean stop"
  explain "Sensors, gateways (they write out the last batch first), the page server and the tunnel are stopped." \
          "The registry stays as it was at the start: A enrolled, B not. Logs and outboxes stay in /tmp/demo-logs and $RUN on $HLBL."
  pause; begin
  need_basics
  CLEANED=0; cleanup

  local leftovers registry on_mac="" and_tunnel=""
  [ $LOCAL = 0 ] && on_mac=' on the Mac'
  [ $LOCAL = 0 ] && and_tunnel=', tunnel closed'
  leftovers=$(vmx leftovers)
  if [ -z "$leftovers" ]; then
    ok "no demo processes left on $HLBL"
  else
    bad "left: $(echo "$leftovers" | head -3 | tr '\n' ';')"
  fi
  [ "$(vmx list | wc -l | tr -d ' ')" = 0 ] && ok "pid file empty" || bad "pid file not empty"
  if curl -s -m 3 -o /dev/null "$URL/health"; then
    bad "page$([ $LOCAL = 0 ] && echo '/tunnel') still answers at $URL"
  else
    ok "page not reachable$and_tunnel"
  fi
  if (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then
    bad "port $PORT still open$on_mac"
  else
    ok "port $PORT closed$on_mac"
  fi
  registry=$(ctr bash $SCRIPTS_IN_CTR/p1-list.sh $MAGIC | tail -1)
  case "$registry" in
    *"A=enrolled B=not-enrolled"*) ok "registry: A enrolled, B not enrolled";;
    *) bad "registry not in the start state: $registry";;
  esac
  finish 6
  CLEANED=1
  [ $FAILS -eq 0 ]
}

# ======================================================================================================
# Main
# ======================================================================================================
summary() {
  hr "SUMMARY"
  local i r t
  for i in 0 1 2 3 4 5 6; do
    eval "r=\$RES$i; t=\$TM$i"
    [ "$r" = "-" ] || printf '  step %s  %-9s %4s s\n' "$i" "$r" "$t"
  done
}

rc=0
if [ -n "$ONLY" ]; then
  # --step N: only that step ("--step 0" needs no container yet, it looks for it itself)
  [ "$ONLY" = 0 ] && CLEANED=1
  if [ "$ONLY" != 0 ]; then need_basics; fi
  "step$ONLY" || rc=1
else
  # the whole demo: a failed preflight stops everything, a failed page server stops the steps
  step0 || {
    say; say "Preflight failed: the demo does not continue. Fix the FAIL lines above (see the hints) and run again."
    summary; CLEANED=1; exit 1
  }
  for n in 1 2 3 4 5 6; do
    "step$n" || rc=1
    [ $n = 1 ] && [ $rc = 1 ] && { say "page server did not start: stopping"; break; }
  done
fi
summary
for i in 0 1 2 3 4 5 6; do
  eval "r=\$RES$i"
  case "$r" in FAIL*) rc=1;; esac
done
exit $rc
