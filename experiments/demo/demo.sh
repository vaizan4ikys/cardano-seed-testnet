#!/bin/bash
# Leader demo on the private Cardano chain: sensors -> gateways -> contract -> chain -> Kupo -> web page.
# Runs on the Mac (it drives the chain VM over ssh) or INSIDE the Ubuntu VM (CHAIN_HOST=local). bash 3.2 compatible.
# Nobody presses a key: the steps run one after the other. While steps 2..5 run, the page shows "Live demo, step N of 4"
# with what is happening and switches to the matching view by itself. In the terminal every check prints PASS or FAIL
# (a FAIL is followed by a "hint:" line); SUMMARY at the end.
#
# For a presentation (the live part takes about 1.5 to 2 minutes):
#   ./demo.sh --prepare     BEFORE the talk, 5+ minutes early (then the first batches are already "Final"): steps 0
#                           and 1. The page, gateway GW01 and its 10 sensors keep running.
#   ./demo.sh --show        IN the talk: steps 2, 3, 4, 5 one after the other, shown on the page. Everything keeps
#                           running afterwards, for questions. Before its clock starts it stops gateway B of an
#                           earlier --show and starts GW01 if --prepare was not run (that time is not counted).
#   ./demo.sh --step 6      AFTER the talk: clean stop; the registry is back to "GW01 approved, GW02 not".
# Other ways to run it:
#   ./demo.sh               the whole demo, steps 0 to 6 (rehearsal: PASS/FAIL for everything). --yes is the same.
#   ./demo.sh --step N      only step N (0..6); it starts what it needs and stops it again at the end
#   ./demo.sh --keep        with --step or the full run: do not stop the processes at the end (stop: --step 6)
#   ./demo.sh --open        open the page in the browser (step 1; macOS only, on Linux the address is printed)
#
# Steps: 0 preflight   1 prepare: page server (+ ssh tunnel in Mac mode), gateway GW01 (approved) and 10 sensors
#        2 GW02 (not approved) sends: the contract refuses it   3 the administrator approves GW02: both gateways write
#        4 the administrator revokes GW01: its sensors go silent   5 GW01 approved again   6 clean stop
#
# Where it runs (setting CHAIN_HOST, see host.sh):
#   Mac -> VM (default on macOS): runs on the MAC and drives the VM "seedvm" over ssh (CHAIN_HOST=seedvm, or another
#     ssh alias); the Mac looks at the page through an ssh tunnel.
#   local (default on Linux, CHAIN_HOST=local): you are INSIDE the Ubuntu VM (for example a VM on a Windows PC or Mac).
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
#   DEMO_B, DEMO_T      gateway batch: B readings or T seconds (defaults 100, 5)
#   DEMO_SILENT         the page marks a sensor silent after this many seconds without a reading (default 30)
#   DEMO_HOLD           --show: seconds between two steps, to look at the result (default 3)
#   DEMO_CLOCK_STRICT   1 = a clock difference Mac/VM (more than 3 s) is a FAIL instead of a warning (default 0)
#
# Processes on the chain host log to /tmp/demo-logs/<name>.log, outboxes are in /tmp/demo-run-<time>/ (not in the repo).
# The registry must end with A enrolled, B not enrolled. Ctrl-C (in any mode) stops everything the demo started,
# the page too, and repairs the registry. Exceptions: --show and "--step 3 --keep" leave gateway B running and
# enrolled; the next --step 6 revokes it. A second --prepare refuses to start while the first one still runs
# (preflight: leftover processes): run --step 6 first.
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HERE=$ROOT/experiments/demo
. "$ROOT/scripts/config.sh"     # REPO, P0_DIR, KUPO_PORT, PAGE_PORT (lab settings)

ONLY=""; OPEN=0; KEEP=0
MODE=full                            # full (0..6), prepare (0, 1), show (2..5) or step (only --step N)
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) ;;                        # there are no pauses any more; kept so that older notes still work
    --prepare) MODE=prepare; KEEP=1;;
    --show) MODE=show; KEEP=1;;
    --open) OPEN=1;;
    --keep) KEEP=1;;
    --step) shift; ONLY=${1:-}; MODE=step;;
    -h|--help) sed -n '2,/^ROOT=/p' "$0" | sed '$d'; exit 0;;
    *) echo "unknown option $1 (try --help)"; exit 1;;
  esac
  shift
done
if [ $MODE = step ]; then
  case "$ONLY" in 0|1|2|3|4|5|6) ;; *) echo "--step needs a number 0..6"; exit 1;; esac
fi

# ======================================================================================================
# Settings (override with environment variables)
# ======================================================================================================
MAGIC=${MAGIC:-42}                   # network magic of net 1 (scripts/lib.sh would give 41 + NET)
PORT=${PORT:-$PAGE_PORT}             # port of the web page on the chain host (and of the ssh tunnel on the Mac)
GWA_PORT=9101; GWB_PORT=9102         # the sensors of gateway A / B send to these ports
B=${DEMO_B:-100}; T=${DEMO_T:-5}     # gateway batch: 100 readings or 5 s (short: the live part must fit 2 minutes)
# page: a sensor is silent after this many seconds without a new reading. Blocks come every 5 s on average, but a gap
# of 20 s happens now and then; 30 s keeps healthy sensors from flickering to "silent".
SILENT=${DEMO_SILENT:-30}
HOLD=${DEMO_HOLD:-3}                 # --show: seconds between two steps
NA=10; NB=5                          # number of sensors of gateway A / B (1 reading per second each)
B_FIRST=11                           # B's sensors are AGRI_011 ... AGRI_015 (A's are AGRI_001 ... AGRI_010)

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
# count_live_from FIRST N: how many of the sensors AGRI_<FIRST> ... AGRI_<FIRST+N-1> are live on the page (B's sensors)
count_live_from() {
  page_state "sum(1 for x in s['sensors']
                  if x['sensor'] in ['AGRI_%03d' % i for i in range($1, $1 + $2)] and not x['silent'])"
}
kupo_ok() { [ "$(page_state "s['kupo']['ok']")" = True ]; }

# ---- the "Live demo" box on the page (server.py: POST /api/demo) ----
# page_phase STEP TAB TITLE DETAIL [STATE]: tell the page which step of the live demo runs, so that the audience
# sees it without anybody switching to the terminal. STEP 1..4 = demo steps 2..5; TAB = the view the page switches to
# (sensors, trust, details or empty); STATE = running (default), done, finished, or off (no box). Also printed here.
page_phase() {
  local json
  json=$(python3 -c '
import json, sys
step, tab, title, detail, state = sys.argv[1:6]
steps = ["GW02 is refused", "Approve GW02", "Revoke GW01", "Approve GW01 again"]
print(json.dumps({"step": int(step), "total": len(steps), "steps": steps, "tab": tab, "title": title,
                  "detail": detail, "state": state}))' "$1" "$2" "$3" "$4" "${5:-running}")
  curl -s -m 3 -X POST -H 'Content-Type: application/json' --data "$json" "$URL/api/demo" > /dev/null 2>&1
  [ -n "$4" ] && say "  [page] $4"
  return 0
}
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
  gw_cmd="$gw_cmd --kupo $KUPO_URL --final-blocks 60"   # follow each batch until final
  vmx start gw$g $VPIPE "$gw_cmd" | tail -1
}

# took_seconds LINE: "took 8.6 s" from the last line of p1-enroll.sh / p1-revoke.sh ("... took 8632 ms"), else empty
took_seconds() {
  printf '%s\n' "$1" | sed -n 's/.*took \([0-9][0-9]*\) ms.*/\1/p' | awk '{ printf "took %.1f s", $1 / 1000 }'
}

# ensure_gw01: gateway A and its sensors run, and the page shows them live (starts them when they are missing)
ensure_gw01() {
  remote_alive gwA || say "  $(start_gateway A)"
  remote_alive sensorsA || say "  $(start_sensors sensorsA $GWA_PORT $NA)"
  wait_for 120 '[ "$(as_number "$(count_live $NA)")" -ge $((NA - 1)) ]' \
    'echo "live sensors of GW01: $(count_live $NA) of $NA"' > /dev/null
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
REVOKED=0          # 1 while step 4 has A revoked
B_ENROLLED=0       # 1 after step 3 enrolled B
INTERRUPTED=0; CLEANED=0
# restore_registry [--keep-b]: read the list and repair it: enrol A if it is missing, revoke B if it is on it
# (--keep-b: leave B enrolled, for "--step 3 --keep", where gateway B keeps running)
restore_registry() {
  [ -n "$CTR" ] || return 0
  local keep_b=0 r
  [ "${1:-}" = --keep-b ] && keep_b=1
  r=$(ctr bash $SCRIPTS_IN_CTR/p1-list.sh $MAGIC | tail -1)
  case "$r" in
    *"REGISTRY size="*) ;;
    *)
      # the list could not be read (for example registry.ref points to a spent coin after an interrupted change):
      # p1-enroll.sh finds the current registry coin by its token and repairs registry.ref; enrolling A is harmless
      say "cleanup: the registry list could not be read ($r); repairing it"
      ctr bash $SCRIPTS_IN_CTR/p1-enroll.sh $MAGIC A | tail -1
      r=$(ctr bash $SCRIPTS_IN_CTR/p1-list.sh $MAGIC | tail -1);;
  esac
  case "$r" in
    *A=not-enrolled*) say "cleanup: enrolling A again"; ctr bash $SCRIPTS_IN_CTR/p1-enroll.sh $MAGIC A | tail -1;;
  esac
  if [ $keep_b = 0 ]; then
    case "$r" in
      *B=enrolled*) say "cleanup: revoking B"; ctr bash $SCRIPTS_IN_CTR/p1-revoke.sh $MAGIC B | tail -1;;
    esac
    B_ENROLLED=0
  fi
  REVOKED=0
}

# reset_for_show: the state the live part starts from: gateway B stopped and not on the list, A on the list and
# sending (an earlier --show leaves B running and enrolled). Runs before the clock of the live part starts.
reset_for_show() {
  page_phase 0 "" "" "" off  # an old "Live demo finished" box goes away while we prepare
  if remote_alive gwB || remote_alive sensorsB; then
    say "  stopping gateway B of an earlier run"
    vmx stop sensorsB 2>/dev/null | sed 's/^/  /'
    vmx stop gwB 2>/dev/null | sed 's/^/  /'
  fi
  restore_registry
  ensure_gw01
}

# Stop everything the demo started and repair the registry (runs once, at the end and on Ctrl-C).
# The processes stop first: a gateway writes out its last batch while it is still enrolled.
cleanup() {
  [ $CLEANED = 1 ] && return 0
  CLEANED=1
  say; say "stopping what the demo started ..."
  vmx stop-all 2>/dev/null | sed 's/^/  /'
  if [ $REVOKED = 1 ] || [ $B_ENROLLED = 1 ]; then restore_registry; fi
  stop_tunnel
  return 0
}
close_master() { [ $LOCAL = 1 ] && return 0; ssh $SSHO -O exit $CHAIN_HOST > /dev/null 2>&1; return 0; }
on_exit() {
  if [ $KEEP = 1 ] && [ $INTERRUPTED = 0 ]; then
    [ $REVOKED = 1 ] && restore_registry --keep-b
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

# sync_demo: Mac mode: copy the demo folder AND the pipeline folder (gateway and page code: the gateway's options
# must match demo.sh) to the chain host. Nothing happens in local mode.
sync_demo() {
  push "$HERE/" $REPO/experiments/demo/
  push "$ROOT/experiments/pipeline/" "$VPIPE/" --exclude __pycache__ --exclude 'outbox*'
}

# For --step N without step 0: find the container, the run directory and the Kupo address.
BASICS_DONE=0
need_basics() {
  [ $BASICS_DONE = 1 ] && return 0
  BASICS_DONE=1
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
  begin

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
# STEP 1: prepare: the page server (and the tunnel), gateway A (approved) with 10 sensors
# ======================================================================================================
# What the audience sees (if they already look): the page with the chain tip moving, GW01's batches arriving, 10 live
# sensors. For a presentation this step runs BEFORE the talk (--prepare): after 5 minutes the first batches are Final.
step1() {
  if [ $LOCAL = 1 ]; then
    hr "STEP 1: prepare: the page server on this machine, gateway GW01 and $NA sensors"
  else
    hr "STEP 1: prepare: the page server on $CHAIN_HOST and the ssh tunnel, gateway GW01 and $NA sensors"
  fi
  explain "The page server reads the chain through Kupo (it keeps nothing of its own) and shows sensors, batches and gateways." \
          "Gateway A (shown as GW01) is on the registry list. $NA sensors send 1 reading per second each; every $T s" \
          "the gateway signs one transaction with its own key and the contract lets it in." \
          "Look for: the page at $URL, the chain tip moving, GW01's batches arriving, $NA sensors live."
  begin
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
  page_phase 0 "" "" "" off  # an old "Live demo" box from an earlier run goes away

  say "  $(start_gateway A)"
  say "  $(start_sensors sensorsA $GWA_PORT $NA)"
  local batches_before
  batches_before=$(as_number "$(gw_field GW01 batches)")
  say "  waiting for 2 batches of GW01 to be sent and to show up on the page (about 20 s) ..."
  wait_for 150 \
    '[ "$(batches_sent A)" -ge 2 ] && [ "$(as_number "$(gw_field GW01 batches)")" -ge $((batches_before + 2)) ]' \
    'echo "sent=$(batches_sent A) page batches=$(gw_field GW01 batches) receipts=$(gw_field GW01 receipts)"'

  local sent page_batches receipts dead live
  sent=$(batches_sent A)
  page_batches=$(as_number "$(gw_field GW01 batches)")
  receipts=$(gw_field GW01 receipts)
  dead=$(dead_count $RUN/outboxA)
  [ "$sent" -ge 2 ] && ok "gateway A sent $sent batches (log)" || bad "gateway A sent only $sent batches"
  if [ "$page_batches" -ge $((batches_before + 2)) ]; then
    ok "page shows $page_batches batches of GW01 (was $batches_before), receipts counter = $receipts"
  else
    bad "page shows only $page_batches batches of GW01 (was $batches_before)"
    hint "Kupo behind? ./demo.sh --step 0; gateway log: /tmp/demo-logs/gwA.log"
  fi
  [ "$dead" -eq 0 ] && ok "no dead-letter batches of A" || bad "$dead dead-letter batches of A"
  live=$(as_number "$(count_live $NA)")
  if [ "$live" -ge $((NA - 1)) ]; then
    ok "$live of $NA sensors of GW01 are live on the page"
  else
    bad "only $live of $NA sensors live on the page"
    hint "readings arrive in batches every ~$T s; wait or raise DEMO_SILENT"
  fi

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
# STEP 2: gateway B (NOT approved) sends: the contract refuses it
# ======================================================================================================
# What the audience sees: view Trust, GW02 "Not approved" with 0 batches; the box says its batch was REFUSED.
step2() {
  hr "STEP 2: gateway GW02 (not approved) sends: the contract refuses it"
  explain "Gateway B (GW02) has its own funded wallet and its own key, but it is not on the registry list." \
          "It builds the same kind of transaction; the contract refuses it, nothing of GW02 reaches the chain." \
          "The gateway moves the batch to dead/ and goes on."
  begin
  need_basics; ensure_page
  local gw02_before        # GW02 batches already on the chain from earlier runs (Kupo shows them again)
  gw02_before=$(as_number "$(gw_field GW02 batches)")
  page_phase 1 trust "Gateway GW02 is not on the approved list" \
    "GW02 starts sending: its own key, its own wallet, the same kind of transaction as GW01 ..."
  say "  $(start_gateway B)"
  say "  $(start_sensors sensorsB $GWB_PORT $NB --first-id $B_FIRST)"
  say "  waiting for the first refused batch (about 10 s) ..."
  wait_for 90 '[ "$(batches_refused B)" -ge 1 ]' 'echo "refused=$(batches_refused B) dead=$(dead_count $RUN/outboxB)"'
  page_phase 1 trust "Gateway GW02 is not on the approved list" \
    "Its batch was REFUSED by the smart contract: nothing of GW02 reaches the chain." done

  local refused dead sent page_batches
  refused=$(batches_refused B); dead=$(dead_count $RUN/outboxB); sent=$(batches_sent B)
  if [ "$refused" -ge 1 ]; then
    ok "gateway B: $refused batch(es) REFUSED by the contract"
  else
    bad "gateway B: nothing refused"; hint "gateway log: /tmp/demo-logs/gwB.log"
  fi
  [ "$dead" -ge 1 ] && ok "$dead batch file(s) moved to dead/ (not on the chain)" || bad "no file in dead/"
  [ "$sent" -eq 0 ] && ok "gateway B sent nothing" || bad "gateway B reports $sent batches sent!"
  page_batches=$(as_number "$(gw_field GW02 batches)")
  if [ "$page_batches" -eq "$gw02_before" ]; then
    ok "page shows no new batch from GW02 (still $page_batches)"
  else
    bad "page shows $((page_batches - gw02_before)) new batch(es) from GW02!"
  fi
  say "  the refusal, one line from the gateway log:"; vmx lines gwB 'REFUSED' 1 | sed 's/^/    /'
  finish 2
  [ $FAILS -eq 0 ]
}

# ======================================================================================================
# STEP 3: the administrator approves gateway B; from then on both gateways write
# ======================================================================================================
# What the audience sees: GW02 turns "Approved" (header 2 of 2), its batches appear; then the view Sensors shows a
# second group "Gateway GW02" with AGRI_011 ... AGRI_015 next to GW01's ten sensors.
step3() {
  hr "STEP 3: the administrator approves GW02: from now on both gateways write"
  explain "The administrator (a dedicated key, not the key of any gateway) puts GW02 on the list with one transaction." \
          "GW02's next batch is accepted by the same contract that refused it a moment ago."
  begin
  need_basics; ensure_page
  remote_alive gwB || say "  $(start_gateway B)"
  remote_alive sensorsB || say "  $(start_sensors sensorsB $GWB_PORT $NB --first-id $B_FIRST)"
  page_phase 2 trust "The administrator approves GW02" \
    "One transaction puts GW02 on the list that is stored on the chain ..."

  say "  the administrator enrols B ..."
  B_ENROLLED=1
  local enrol_out took
  enrol_out=$(ctr bash $SCRIPTS_IN_CTR/p1-enroll.sh $MAGIC B | tail -1); say "    $enrol_out"
  took=$(took_seconds "$enrol_out")
  case "$enrol_out" in
    OK:*) ok "registry: B enrolled ($took)";;
    *"already enrolled"*) ok "registry: B was enrolled already";;
    *) bad "enrol of B failed: $enrol_out";;
  esac
  page_phase 2 trust "The administrator approves GW02" \
    "GW02 is on the list now${took:+ ($took)}. Its next batch goes through ..."

  local sent_at_enrol gw02_before
  sent_at_enrol=$(batches_sent B); gw02_before=$(as_number "$(gw_field GW02 batches)")
  say "  waiting for a batch of B to be accepted and to show up on the page (about 15 s) ..."
  wait_for 120 \
    '[ "$(batches_sent B)" -gt $sent_at_enrol ] && [ "$(as_number "$(gw_field GW02 batches)")" -gt $gw02_before ]' \
    'echo "B sent=$(batches_sent B) page: GW02 batches=$(gw_field GW02 batches)"'
  page_phase 2 sensors "The administrator approves GW02" \
    "GW02's batches are accepted: both gateways write. Its sensors AGRI_011 ... AGRI_015 appear." done
  wait_for 30 '[ "$(as_number "$(count_live_from $B_FIRST $NB)")" -ge $((NB - 1)) ]' \
    'echo "live sensors of GW02: $(count_live_from $B_FIRST $NB) of $NB"' > /dev/null

  local sent_b page_b approved_b live_b
  sent_b=$(batches_sent B); page_b=$(as_number "$(gw_field GW02 batches)"); approved_b=$(gw_field GW02 approved)
  live_b=$(as_number "$(count_live_from $B_FIRST $NB)")
  if [ "$sent_b" -gt "$sent_at_enrol" ]; then
    ok "gateway B sent $((sent_b - sent_at_enrol)) batch(es) after the enrolment"
  else
    bad "gateway B sent no batch after the enrolment"; hint "gateway log: /tmp/demo-logs/gwB.log"
  fi
  if [ "$page_b" -gt "$gw02_before" ]; then
    ok "page shows $((page_b - gw02_before)) new batch(es) of GW02"
  else
    bad "page shows no new batch of GW02"
  fi
  [ "$approved_b" = True ] && ok "page: GW02 is approved" || bad "page: GW02 approved = '$approved_b'"
  if [ "$live_b" -ge $((NB - 1)) ]; then
    ok "$live_b of $NB sensors of GW02 are live on the page (AGRI_011 ...)"
  else
    bad "only $live_b of $NB sensors of GW02 live on the page"
  fi
  finish 3
  [ $FAILS -eq 0 ]
}

# ======================================================================================================
# STEP 4: the administrator revokes gateway A while its sensors keep sending
# ======================================================================================================
# What the audience sees: GW01 turns "Not approved" (header 1 of 2); in the view Sensors GW01's ten sensors turn
# "Silent" after $SILENT s, GW02's five stay live.
step4() {
  hr "STEP 4: the administrator revokes GW01 while its sensors keep sending"
  explain "The administrator replaces the registry coin with a new list without A. A's sensors keep sending, but A's" \
          "batches are refused now (dead-letter): these readings are lost. GW02 is not affected."
  begin
  need_basics; ensure_page; ensure_gw01

  local refused_before b_sent_before
  refused_before=$(batches_refused A); b_sent_before=$(batches_sent B)
  page_phase 3 trust "The administrator removes GW01 from the list" "One transaction: GW01 is no longer approved ..."
  say "  revoking A ..."; REVOKED=1
  local revoke_out took
  revoke_out=$(ctr bash $SCRIPTS_IN_CTR/p1-revoke.sh $MAGIC A | tail -1); say "    $revoke_out"
  took=$(took_seconds "$revoke_out")
  case "$revoke_out" in
    OK:*"list size now"*) ok "registry: A revoked ($took)";;
    *) bad "revoke failed: $revoke_out";;
  esac
  page_phase 3 sensors "The administrator removes GW01 from the list" \
    "GW01's batches are refused now. Its sensors turn Silent after $SILENT s without new data; GW02 keeps writing."

  say "  waiting for a refused batch of A and for its sensors to turn silent on the page (about $((SILENT + 10)) s) ..."
  wait_for 150 \
    '[ "$(batches_refused A)" -gt $refused_before ] && [ "$(as_number "$(count_silent $NA)")" -ge $((NA - 1)) ]' \
    'echo "A refused=$(( $(batches_refused A) - refused_before )) silent sensors of GW01=$(count_silent $NA) of $NA"'
  page_phase 3 sensors "The administrator removes GW01 from the list" \
    "GW01's sensors are Silent: their readings are refused. GW02's sensors stay live." done

  local refused_now silent
  refused_now=$(batches_refused A); silent=$(as_number "$(count_silent $NA)")
  if [ "$refused_now" -gt "$refused_before" ]; then
    ok "A's batches are refused after the revoke ($((refused_now - refused_before)) REFUSED lines)"
  else
    bad "A is not refused after the revoke"
  fi
  [ "$silent" -ge $((NA - 1)) ] && ok "page: $silent of $NA sensors of GW01 silent" \
    || bad "page: only $silent of $NA sensors of GW01 silent"
  if remote_alive gwB; then
    if [ "$(batches_sent B)" -gt "$b_sent_before" ]; then ok "GW02 kept writing meanwhile"
    else bad "GW02 sent nothing meanwhile"; fi
  fi
  say "  one refusal:"; vmx lines gwA REFUSED 50 | tail -1 | sed 's/^/    /'
  finish 4
  [ $FAILS -eq 0 ]
}

# ======================================================================================================
# STEP 5: gateway A is approved again: its sensors wake up
# ======================================================================================================
# What the audience sees: GW01 "Approved" again, its next batches go through, its sensors turn live again.
step5() {
  hr "STEP 5: GW01 is approved again: its sensors wake up"
  explain "The administrator puts A back on the list. A's next batches are accepted again." \
          "The readings refused in the meantime stay lost: the gateway does not send them twice."
  begin
  need_basics; ensure_page
  remote_alive gwA || say "  $(start_gateway A)"
  remote_alive sensorsA || say "  $(start_sensors sensorsA $GWA_PORT $NA)"
  page_phase 4 trust "GW01 is approved again" "One transaction puts GW01 back on the list ..."

  say "  enrolling A again ..."
  local enrol_out took
  enrol_out=$(ctr bash $SCRIPTS_IN_CTR/p1-enroll.sh $MAGIC A | tail -1); say "    $enrol_out"
  took=$(took_seconds "$enrol_out")
  case "$enrol_out" in
    OK:*) ok "registry: A enrolled again ($took)"; REVOKED=0;;
    *"already enrolled"*) ok "registry: A was enrolled already"; REVOKED=0;;
    *) bad "enrol failed: $enrol_out";;
  esac
  page_phase 4 sensors "GW01 is approved again" \
    "GW01 is on the list again${took:+ ($took)}: its next batches go through ..."

  local sent_at_enrol; sent_at_enrol=$(batches_sent A)
  say "  waiting for a new batch of A and for its sensors to wake up (about 15 s) ..."
  wait_for 120 \
    '[ "$(batches_sent A)" -gt $sent_at_enrol ] && [ "$(as_number "$(count_live $NA)")" -ge $((NA - 1)) ]' \
    'echo "new batches of A=$(( $(batches_sent A) - sent_at_enrol )) live sensors of GW01=$(count_live $NA)"'
  page_phase 4 sensors "GW01 is approved again" \
    "Its sensors are live again: both gateways write. End of the live demo." done

  local sent_after live
  sent_after=$(batches_sent A); live=$(as_number "$(count_live $NA)")
  [ "$sent_after" -gt "$sent_at_enrol" ] && ok "after re-enrol: $((sent_after - sent_at_enrol)) new batch(es) sent" \
    || bad "no new batches after re-enrol"
  [ "$live" -ge $((NA - 1)) ] && ok "page: $live of $NA sensors of GW01 live again" \
    || bad "page: only $live sensors of GW01 live again"
  [ "$REVOKED" = 0 ] || restore_registry --keep-b
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
          "The registry goes back to the start: A enrolled, B not (B is revoked again)." \
          "Logs and outboxes stay in /tmp/demo-logs and $RUN on $HLBL."
  begin
  need_basics
  page_phase 0 "" "" "" off  # no "Live demo" box any more (the server stops anyway)
  REVOKED=1; B_ENROLLED=1    # a new process does not know what earlier runs changed: always repair (also on Ctrl-C)
  CLEANED=0; cleanup
  restore_registry          # also repairs a list left by an earlier "--step 3 --keep" (B still enrolled)

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
case $MODE in
  step)
    # --step N: only that step ("--step 0" needs no container yet, it looks for it itself)
    [ "$ONLY" = 0 ] && CLEANED=1
    if [ "$ONLY" != 0 ]; then need_basics; fi
    "step$ONLY" || rc=1
    ;;
  prepare)
    # before the talk: preflight and step 1; the page, GW01 and its sensors keep running (KEEP=1)
    step0 || {
      say; say "Preflight failed. Fix the FAIL lines above (see the hints) and run again."; summary; CLEANED=1; exit 1
    }
    step1 || rc=1
    say
    if [ $rc = 0 ]; then
      say "READY. The page, GW01 and its sensors keep running. Open $URL; start the live part in the talk with:"
      say "  ./experiments/demo/demo.sh --show        (about 1.5 to 2 minutes; best 5+ minutes from now)"
    fi
    ;;
  show)
    # in the talk: steps 2..5 one after the other, a short hold in between; everything keeps running (KEEP=1)
    need_basics; ensure_page
    say "getting the start state (not part of the live time) ..."
    reset_for_show
    show_start=$SECONDS
    for n in 2 3 4 5; do
      "step$n" || rc=1
      [ $n != 5 ] && sleep "$HOLD"
    done
    show_time=$((SECONDS - show_start))
    page_phase 4 sensors "Live demo finished" \
      "Everything keeps running: look around in Sensors, Trust and Details." finished
    say
    say "the live part took $show_time s ($((show_time / 60)) min $((show_time % 60)) s). Stop later with --step 6."
    ;;
  full)
    # the whole demo: a failed preflight stops everything, a failed step 1 (page, GW01) stops the steps
    step0 || {
      say; say "Preflight failed: the demo does not continue. Fix the FAIL lines above (see the hints) and run again."
      summary; CLEANED=1; exit 1
    }
    for n in 1 2 3 4 5 6; do
      "step$n" || rc=1
      [ $n = 1 ] && [ $rc = 1 ] && { say "the page or GW01 did not start: stopping"; break; }
    done
    ;;
esac
summary
for i in 0 1 2 3 4 5 6; do
  eval "r=\$RES$i"
  case "$r" in FAIL*) rc=1;; esac
done
exit $rc
