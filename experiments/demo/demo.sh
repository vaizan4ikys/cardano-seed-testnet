#!/bin/bash
# Leader demo on the private Cardano chain (sensors -> gateways -> contract -> chain -> Kupo -> web page).
# Runs on the MAC and drives seedvm over ssh. bash 3.2 compatible (macOS).
#
#   ./demo.sh                 the whole demo, a pause "press Enter" before every step
#   ./demo.sh --yes           no pauses (rehearsal: tells you with PASS/FAIL whether everything works)
#   ./demo.sh --step N        only step N (0..6); it starts what it needs and stops it again at the end
#   ./demo.sh --keep          with --step: do not stop the processes at the end (stop later with --step 6)
#   ./demo.sh --open          open http://127.0.0.1:8088 in the browser (step 1)
#
# Steps: 0 preflight  1 page server + tunnel  2 gateway GW01 (enrolled) + 10 sensors  3 gateway GW02 (NOT enrolled)
#        4 revoke GW01, then enrol again  5 one sensor goes silent  6 clean stop
# Processes on seedvm log to /tmp/demo-logs/<name>.log, outboxes are in /tmp/demo-run-<time>/ (not in the repo).
# The registry must end with A enrolled, B not enrolled (also after Ctrl-C: the cleanup repairs it).
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HERE=$ROOT/experiments/demo
YES=0; ONLY=""; OPEN=0; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1;; --open) OPEN=1;; --keep) KEEP=1;;
    --step) shift; ONLY=${1:-};;
    -h|--help) sed -n '2,15p' "$0"; exit 0;;
    *) echo "unknown option $1 (try --help)"; exit 1;;
  esac; shift
done
case "$ONLY" in ""|0|1|2|3|4|5|6) ;; *) echo "--step needs a number 0..6"; exit 1;; esac

# ---- settings (override with environment variables) ----
MAGIC=${MAGIC:-42}; PORT=${PORT:-8088}; GWA_PORT=9101; GWB_PORT=9102
B=${DEMO_B:-100}; T=${DEMO_T:-10}            # batch: 100 readings or 10 s
SILENT=${DEMO_SILENT:-40}                     # page: sensor silent after this many seconds without a new reading from the chain
NA=10; NB=5                                   # sensors of gateway A / B (1 reading per second each)
VPIPE=cardano-seed-testnet/experiments/pipeline
CTR=""; RUN=""; KUPO_URL=""
SSHO="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ControlMaster=auto -o ControlPath=/tmp/demo-cm-%C -o ControlPersist=120"
TUNNEL_PID=/tmp/demo-tunnel.pid
URL=http://127.0.0.1:$PORT

# ---- helpers ----
vm() { local o rc=0; o=$(ssh -n $SSHO seedvm "$@" 2>&1) || rc=$?; [ -n "$o" ] && { printf '%s\n' "$o" | grep -v -E "post-quantum|vulnerable|upgraded" || true; }; return $rc; }
vmx() { vm "bash cardano-seed-testnet/experiments/demo/remote.sh $(printf '%q ' "$@")"; }
ctr() { vm "docker exec -e P0_DIR=/tmp/p0n $CTR $*"; }
say() { printf '%s\n' "$*"; }
hr() { printf '\n==================== %s\n' "$*"; }
explain() { printf '\n'; for l in "$@"; do printf '  %s\n' "$l"; done; printf '\n'; }
pause() { [ $YES = 1 ] && return 0; printf '  [press Enter to start this step] '; read -r _ < /dev/tty; }
FAILS=0; NCHK=0
ok() { NCHK=$((NCHK+1)); say "  PASS  $*"; }
bad() { NCHK=$((NCHK+1)); FAILS=$((FAILS+1)); say "  FAIL  $*"; }
hint() { say "        hint: $*"; }
api() { curl -s -m 5 "$URL/api/state"; }
# st 'python expression using s (the state)' -> prints the value (empty on error)
st() { api | python3 -c 'import sys,json; s=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1" 2>/dev/null; }
gwv() { st "[g for g in s['gateways'] if g['name']=='$1'][0]['$2']"; }       # gwv GW01 batches
nsilent() { st "sum(1 for x in s['sensors'] if x['sensor'] in ['AGRI_%03d'%i for i in range(1,$1+1)] and x['silent'])"; }
nlive() { st "sum(1 for x in s['sensors'] if x['sensor'] in ['AGRI_%03d'%i for i in range(1,$1+1)] and not x['silent'])"; }
is_silent() { st "[x['silent'] for x in s['sensors'] if x['sensor']=='$1'][0]"; }
num() { case "$1" in ''|*[!0-9]*) echo 0;; *) echo "$1";; esac; }
cnt() { num "$(vmx count "$1" "$2")"; }
sent() { cnt gw$1 '^[0-9:]* sent: '; }          # batches sent by gateway A or B (log)
refused() { cnt gw$1 REFUSED; }
kupo_ok() { [ "$(st "s['kupo']['ok']")" = True ]; }
# wait_for TIMEOUT "condition (shell)" "status (shell, printed each round)"
wait_for() {
  local t=$1 cond=$2 stat=$3 start=$SECONDS
  while :; do
    if eval "$cond"; then printf '\n'; return 0; fi
    [ $((SECONDS - start)) -ge "$t" ] && { printf '\n'; return 1; }
    printf '\r    [%3ds] %s   ' "$((SECONDS - start))" "$(eval "$stat")"
    sleep 3
  done
}

# ---- process control ----
ensure_run() {   # a new run directory when no demo process is running (fresh outboxes), else the current one
  RUN=$(vmx rundir | tail -1)
  if [ -z "$RUN" ] || [ -z "$(vmx list)" ]; then RUN=$(vmx newrun | tail -1); fi
}
start_server() {
  vmx start server $VPIPE "python3 -u server.py --port $PORT --silent-after $SILENT --kupo $KUPO_URL" | tail -1
}
start_tunnel() {
  if [ -f $TUNNEL_PID ] && kill -0 "$(cat $TUNNEL_PID)" 2>/dev/null; then return 0; fi
  ssh -o ControlPath=none -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -N -L $PORT:127.0.0.1:$PORT seedvm < /dev/null > /tmp/demo-tunnel.log 2>&1 &
  echo $! > $TUNNEL_PID
}
stop_tunnel() { [ -f $TUNNEL_PID ] && { kill "$(cat $TUNNEL_PID)" 2>/dev/null; rm -f $TUNNEL_PID; }; return 0; }
SEQK=0
start_gateway() {   # start_gateway A|B   (A = GW01 on the list, B = GW02 not on the list)
  local g=$1 id port; if [ $g = A ]; then id=GW01; port=$GWA_PORT; else id=GW02; port=$GWB_PORT; fi
  vmx start gw$g $VPIPE "env GATEWAY=$g python3 -u gateway.py --B $B --T $T --listen-port $port --outbox $RUN/outbox$g --gateway-id $id --submit command --submit-command './submit_contract.sh {file} {hash}' --retry 5" | tail -1
}
start_sensors() {   # start_sensors NAME PORT COUNT [extra args]   (unique sequence numbers: epoch + 1000000 * k)
  local name=$1 port=$2 n=$3; shift 3
  SEQK=$((SEQK + 1))
  vmx start $name $VPIPE "python3 -u sensor.py --sensors $n --interval 1 --port $port --seq-start $(( $(date +%s) + 1000000 * SEQK )) $*" | tail -1
}
STARTED=0; REVOKED=0; INTERRUPTED=0; CLEANED=0
restore_registry() {
  [ -n "$CTR" ] || return 0
  local r; r=$(ctr bash /tmp/p0-scripts/p1-list.sh $MAGIC | tail -1)
  case "$r" in *A=not-enrolled*) say "cleanup: enrolling A again"; ctr bash /tmp/p0-scripts/p1-enroll.sh $MAGIC A | tail -1;; esac
  case "$r" in *B=enrolled*) say "cleanup: revoking B"; ctr bash /tmp/p0-scripts/p1-revoke.sh $MAGIC B | tail -1;; esac
  REVOKED=0
}
cleanup() {
  [ $CLEANED = 1 ] && return 0
  CLEANED=1
  say; say "stopping what the demo started ..."
  [ $REVOKED = 1 ] && restore_registry
  vmx stop-all 2>/dev/null | sed 's/^/  /'
  stop_tunnel
  return 0
}
close_master() { ssh $SSHO -O exit seedvm > /dev/null 2>&1; return 0; }
on_exit() { if [ $KEEP = 1 ] && [ $INTERRUPTED = 0 ]; then [ $REVOKED = 1 ] && restore_registry; else cleanup; fi; close_master; }
on_int() { INTERRUPTED=1; say; say "interrupted"; cleanup; close_master; trap - EXIT; exit 130; }
trap on_exit EXIT
trap on_int INT TERM

# ---- results ----
RES0=-; RES1=-; RES2=-; RES3=-; RES4=-; RES5=-; RES6=-
TM0=0; TM1=0; TM2=0; TM3=0; TM4=0; TM5=0; TM6=0
begin() { FAILS=0; NCHK=0; S0=$SECONDS; }
finish() { local r=PASS; [ $FAILS -gt 0 ] && r="FAIL($FAILS)"; eval "RES$1=\$r; TM$1=\$((SECONDS - S0))"; say; say "  step $1: $r, $((SECONDS - S0)) s"; }
sync_demo() { rsync -a -e "ssh $SSHO" "$HERE/" seedvm:cardano-seed-testnet/experiments/demo/ 2>&1 | grep -v -E "post-quantum|vulnerable|upgraded"; return 0; }
need_basics() {   # for --step N without step 0: find the container, run dir, Kupo URL
  sync_demo
  [ -n "$CTR" ] || CTR=$(vmx ctr | tail -1)
  [ -n "$CTR" ] || { say "pool 1 container not found: is the chain up?"; exit 1; }
  [ -n "$KUPO_URL" ] || KUPO_URL=http://$(vm "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' $CTR" | awk '{print $1}'):1442
  ensure_run
}

############################################################ step 0
step0() {
  hr "STEP 0: preflight (is everything ready?)"
  explain "We check the chain, the indexer (Kupo), the clocks, the disk, the scripts in the container and the registry list." \
          "Look for: only PASS lines. On a FAIL the demo stops and says what to do."
  pause; begin
  local f
  # Mac disk
  f=$(df -k / | awk 'NR==2 {print int($4/1048576)}')
  [ "${f:-0}" -ge 6 ] && ok "Mac disk free: ${f} GB" || { bad "Mac disk free only ${f} GB (< 6)"; hint "free some space"; }
  # ssh
  if vm "true"; then ok "ssh to seedvm works"; else bad "cannot ssh to seedvm"; hint "is the VM running? try: ssh seedvm"; finish 0; return 1; fi
  f=$(vm "df -BG --output=avail / | tail -1 | tr -dc 0-9")
  [ "${f:-0}" -ge 6 ] && ok "VM disk free: ${f} GB" || { bad "VM disk free only ${f:-?} GB (< 6)"; hint "clean up on seedvm (docker system prune, old logs)"; }
  sync_demo
  # container
  CTR=$(vmx ctr | tail -1)
  if [ -n "$CTR" ]; then ok "pool 1 container up: $CTR"; else bad "pool 1 container not running"; hint "start the chain: fresh.sh, or on seedvm: ./run.sh"; finish 0; return 1; fi
  # tip advancing
  local t1 t2
  t1=$(vmx tip | tail -1); t2=$t1
  for i in 1 2 3 4 5 6 7 8 9 10; do sleep 3; t2=$(vmx tip | tail -1); [ "${t2%% *}" -gt "${t1%% *}" ] 2>/dev/null && break; done
  if [ -n "$t1" ] && [ "${t2%% *}" -gt "${t1%% *}" ] 2>/dev/null; then ok "chain tip advancing: block ${t1%% *} -> ${t2%% *} in $((i * 3)) s"
  else bad "chain tip not advancing for 30 s (${t1:-none} -> ${t2:-none})"; hint "the chain is stalled: see README 'what to do if'; a fresh chain: fresh.sh"; fi
  # Kupo
  local ks b
  KUPO_URL=http://$(vm "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' $CTR" | awk '{print $1}'):1442
  ks=$(vm "cd $VPIPE && ./kupo.sh status")
  b=$(printf '%s\n' "$ks" | sed -n 's/.*behind: *\(-\{0,1\}[0-9]*\) slots.*/\1/p' | tail -1)
  if [ -n "$b" ] && [ "$b" -le 30 ]; then ok "Kupo running and caught up (behind $b slots) at $KUPO_URL"
  else bad "Kupo not ok: $(printf '%s\n' "$ks" | tr '\n' ' ' | cut -c1-160)"; hint "on seedvm: cd $VPIPE && ./kupo.sh start   (after a fresh chain: ./kupo.sh wipe first)"; fi
  # clocks: (1) the VM clock and the chain agree (syncProgress of the node), (2) VM clock against the Mac clock
  local sp; sp=$(echo "$t2" | awk '{print $3}')
  if [ -n "$sp" ] && python3 -c "import sys; sys.exit(0 if float('$sp') >= 99.9 else 1)" 2>/dev/null; then ok "VM clock agrees with the chain time (node sync progress $sp %)"
  else bad "node sync progress is ${sp:-?} % (VM clock and chain time disagree)"; hint "the chain needs a restart after a clock jump: fresh.sh (new chain)"; fi
  local m0 v m1 d
  m0=$(python3 -c 'import time; print(time.time())'); v=$(vm "date +%s.%N"); m1=$(python3 -c 'import time; print(time.time())')
  d=$(python3 -c "print(round($v - ($m0 + $m1) / 2, 1))" 2>/dev/null)
  if [ -n "$d" ] && python3 -c "import sys; sys.exit(0 if abs($d) < 3 else 1)"; then ok "VM clock differs from the Mac clock by $d s"
  elif [ "${DEMO_CLOCK_STRICT:-0}" = 1 ]; then bad "VM clock differs from the Mac clock by ${d:-?} s (> 3 s)"; hint "on seedvm: sudo timedatectl set-ntp true (this jumps the clock: the chain must be restarted afterwards)"
  else say "  WARN  VM clock differs from the Mac clock by ${d:-?} s (VM minus Mac). Not blocking: sensors, gateways, node and page all use the VM clock;"
       say "        times seen on the page are VM times. (DEMO_CLOCK_STRICT=1 makes this a FAIL.)"; fi
  # sync + scripts in the container
  say "  (copying the pipeline, contract and demo scripts to seedvm and into the container)"
  rsync -a -e "ssh $SSHO" --exclude __pycache__ --exclude 'outbox*' "$ROOT/experiments/pipeline/" seedvm:$VPIPE/ 2>&1 | grep -v -E "post-quantum|vulnerable|upgraded"
  rsync -a -e "ssh $SSHO" "$ROOT/experiments/contract/in-container/" seedvm:cardano-seed-testnet/experiments/contract/in-container/ 2>&1 | grep -v -E "post-quantum|vulnerable|upgraded"
  rsync -a -e "ssh $SSHO" "$HERE/" seedvm:cardano-seed-testnet/experiments/demo/ 2>&1 | grep -v -E "post-quantum|vulnerable|upgraded"
  vm "cd cardano-seed-testnet/experiments && docker cp contract/in-container/. $CTR:/tmp/p0-scripts/ && docker cp demo/in-container/p1-list.sh $CTR:/tmp/p0-scripts/p1-list.sh" > /dev/null
  local miss
  miss=$(ctr "bash -c 'cd /tmp/p0n && for f in /tmp/p0-scripts/p0-lib.sh /tmp/p0-scripts/p1-batch.sh /tmp/p0-scripts/p1-enroll.sh /tmp/p0-scripts/p1-revoke.sh /tmp/p0-scripts/p1-list.sh gateway_write.plutus registry.ref policy.id token.hex admin.skey gwA.skey gwB.skey; do [ -f \$f ] || echo \$f; done'")
  [ -z "$miss" ] && ok "scripts, policy files and keys are in the container" || { bad "missing in the container: $(echo $miss)"; hint "run experiments/contract/p0.sh (or fresh.sh)"; }
  # registry
  local r
  r=$(ctr bash /tmp/p0-scripts/p1-list.sh $MAGIC | tail -1)
  case "$r" in
    *"A=enrolled B=not-enrolled"*) ok "registry list: A enrolled, B not enrolled ($r)";;
    *) bad "registry list is wrong: $r"; hint "enrol A:  ssh seedvm \"docker exec -e P0_DIR=/tmp/p0n $CTR bash /tmp/p0-scripts/p1-enroll.sh $MAGIC A\"   revoke B: same with p1-revoke.sh ... B";;
  esac
  # gateways.json against the real wallets
  local ga gb
  ga=$(ctr cat /tmp/p0n/gwA.addr); gb=$(ctr cat /tmp/p0n/gwB.addr)
  if vm "grep -q $ga $VPIPE/gateways.json && grep -q $gb $VPIPE/gateways.json"; then ok "gateways.json holds the wallet addresses of A and B"
  else bad "gateways.json does not match the wallets of A/B (the page would show 'unknown signer')"; hint "write {\"GW01\": \"$ga\", \"GW02\": \"$gb\"} into experiments/pipeline/gateways.json (fresh.sh does this)"; fi
  # leftovers and ports
  local lo p8 p1 p2
  lo=$(vmx leftovers)
  [ -z "$lo" ] && ok "no leftover demo processes on seedvm" || { bad "leftover processes: $(echo "$lo" | head -3 | tr '\n' ';' | cut -c1-200)"; hint "./demo.sh --step 6 (clean stop), or kill them by hand"; }
  p8=$(vmx portfree $PORT | tail -1); p1=$(vmx portfree $GWA_PORT | tail -1); p2=$(vmx portfree $GWB_PORT | tail -1)
  if [ "$p8" = free ] && [ "$p1" = free ] && [ "$p2" = free ]; then ok "ports $PORT, $GWA_PORT, $GWB_PORT are free on seedvm"
  else bad "a port is busy on seedvm (page $p8, gateway A $p1, gateway B $p2)"; hint "find the owner: ssh seedvm 'ss -ltnp | grep -E \"$PORT|$GWA_PORT|$GWB_PORT\"'; set another page port with PORT=8089 ./demo.sh"; fi
  if (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && [ ! -f $TUNNEL_PID ]; then bad "port $PORT is busy on the Mac (an old tunnel?)"; hint "lsof -i :$PORT ; kill the old ssh -L"
  else ok "port $PORT is free on the Mac"; fi
  finish 0
  [ $FAILS -eq 0 ]
}

############################################################ step 1
step1() {
  hr "STEP 1: start the page server on seedvm and the ssh tunnel"
  explain "The page server reads the chain through Kupo (it keeps nothing of its own) and shows sensors, batches and gateways." \
          "Look for: the page opens at $URL; it shows the chain tip moving and Kupo 'ok'." \
          "Old sensor values from earlier runs may be on it: they go 'silent' after $SILENT s, that is normal."
  pause; begin
  need_basics; ensure_run
  say "  $(start_server)"; STARTED=1
  start_tunnel
  if wait_for 40 kupo_ok 'echo waiting for the page'; then ok "page answers through the tunnel; Kupo ok"
  else bad "page did not answer at $URL within 40 s"; hint "see /tmp/demo-logs/server.log on seedvm, /tmp/demo-tunnel.log on the Mac; port busy: PORT=8089 ./demo.sh"; fi
  local tb; tb=$(st "s['tip']['block']")
  [ -n "$tb" ] && ok "page shows the chain tip: block $tb" || bad "page has no tip"
  say "  run directory on seedvm: $RUN"
  say "  >>> open $URL in the browser <<<"
  [ $OPEN = 1 ] && open "$URL"
  finish 1
  [ $FAILS -eq 0 ]
}
ensure_page() { # for steps 2..5 when started alone
  kupo_ok || step1_quiet
}
step1_quiet() {
  vmx start server $VPIPE "python3 -u server.py --port $PORT --silent-after $SILENT --kupo $KUPO_URL" | tail -1; STARTED=1
  start_tunnel
  wait_for 40 kupo_ok 'echo waiting for the page' || say "  page does not answer"
}

############################################################ step 2
step2() {
  hr "STEP 2: gateway GW01 (enrolled) and $NA sensors"
  explain "Gateway A (shown as GW01) is on the registry list. $NA sensors send 1 reading per second each." \
          "The gateway makes a batch every $T s, signs one transaction with its own key and the contract lets it in." \
          "Look at the page: batches appearing in the list, the depth bar of each batch growing as blocks are added," \
          "the 'receipts' counter of GW01 rising by one per batch, the sensor values and charts moving."
  pause; begin
  need_basics; ensure_page
  say "  $(start_gateway A)"; STARTED=1
  say "  $(start_sensors sensorsA $GWA_PORT $NA)"
  local b0; b0=$(num "$(gwv GW01 batches)")
  say "  waiting for 3 batches to be sent and to show up on the page (about 40 s) ..."
  wait_for 150 '[ "$(sent A)" -ge 3 ] && [ "$(num "$(gwv GW01 batches)")" -ge $((b0 + 3)) ]' \
    'echo "sent=$(sent A) page batches=$(gwv GW01 batches) receipts=$(gwv GW01 receipts)"'
  local sent pg rc dead
  sent=$(sent A); pg=$(num "$(gwv GW01 batches)"); rc=$(gwv GW01 receipts); dead=$(num "$(vmx deadcount $RUN/outboxA | tail -1)")
  [ "$sent" -ge 3 ] && ok "gateway A sent $sent batches (log)" || bad "gateway A sent only $sent batches"
  [ "$pg" -ge $((b0 + 3)) ] && ok "page shows $pg batches of GW01 (was $b0), receipts counter = $rc" || { bad "page shows only $pg batches of GW01 (was $b0)"; hint "Kupo behind? ./demo.sh --step 0; gateway log: /tmp/demo-logs/gwA.log"; }
  local dp; dp=$(num "$(st "([b['depth'] for b in s['batches'] if b['signer_name']=='GW01'] + [0])[0] or 0")")
  [ "$dp" -ge 1 ] && ok "depth bar: the newest batch of GW01 is $dp blocks deep (it grows with every block)" || bad "the newest batch of GW01 has no depth yet"
  [ "$(num "$rc")" -ge 3 ] && ok "receipts counter of GW01 is $rc" || bad "receipts counter of GW01 is '$rc' (expected >= 3)"
  [ "$dead" -eq 0 ] && ok "no dead-letter batches of A" || bad "$dead dead-letter batches of A"
  local nl; nl=$(num "$(nlive $NA)")
  [ "$nl" -ge $((NA - 1)) ] && ok "$nl of $NA sensors are live on the page" || { bad "only $nl of $NA sensors live on the page"; hint "readings arrive in batches every ~$T s; wait or raise DEMO_SILENT"; }
  say "  last gateway lines:"; vmx lines gwA '^[0-9:]* (batch|sent)' 4 | sed 's/^/    /'
  finish 2
  [ $FAILS -eq 0 ]
}

############################################################ step 3
step3() {
  hr "STEP 3: gateway GW02 (NOT enrolled) with 5 sensors"
  explain "Gateway B (GW02) has its own funded wallet and its own key, but it is not on the registry list." \
          "It builds the same kind of transaction. The contract (checked by the node when the transaction is submitted)" \
          "refuses it: no batch of GW02 is ever written to the chain. The gateway moves the batch to dead/ and goes on." \
          "Look for: the REFUSED line below, 'dead/' filling up, and on the page GW02 stays at 0 batches."
  pause; begin
  need_basics; ensure_page
  say "  $(start_gateway B)"; STARTED=1
  say "  $(start_sensors sensorsB $GWB_PORT $NB)"
  say "  waiting for 2 refused batches (about 35 s) ..."
  wait_for 120 '[ "$(refused B)" -ge 2 ]' 'echo "refused=$(refused B) dead=$(vmx deadcount $RUN/outboxB | tail -1)"'
  local rf dd sd g2 other
  rf=$(refused B); dd=$(num "$(vmx deadcount $RUN/outboxB | tail -1)"); sd=$(sent B); g2=$(num "$(gwv GW02 batches)")
  [ "$rf" -ge 2 ] && ok "gateway B: $rf batches REFUSED by the contract" || { bad "gateway B: only $rf refused"; hint "gateway log: /tmp/demo-logs/gwB.log"; }
  [ "$dd" -ge 2 ] && ok "$dd batch files moved to dead/ (not on the chain)" || bad "only $dd files in dead/"
  [ "$sd" -eq 0 ] && ok "gateway B sent nothing" || bad "gateway B reports $sd batches sent!"
  sleep 6
  g2=$(num "$(gwv GW02 batches)")
  [ "$g2" -eq 0 ] && ok "page shows 0 batches from GW02" || bad "page shows $g2 batches from GW02!"
  say "  the refusal, one line from the gateway log:"; vmx lines gwB 'REFUSED' 1 | sed 's/^/    /'
  say "  the batch moved to dead/:"; vm "ls $RUN/outboxB/dead | head -2" | sed 's/^/    /'
  vmx stop gwB | sed 's/^/  /'; vmx stop sensorsB | sed 's/^/  /'
  finish 3
  [ $FAILS -eq 0 ]
}

############################################################ step 4
step4() {
  hr "STEP 4: revoke GW01 while its sensors keep sending, then enrol it again"
  explain "The administrator (a dedicated key, not the key of any gateway) replaces the registry coin with a new list without A." \
          "A's sensors keep sending. A's next batches are refused (dead-letter) and the readings are lost." \
          "Look for: the REFUSED lines; on the page the sensors turn 'silent' after $SILENT s without new data." \
          "Then we enrol A again: new batches flow, the sensors on the page wake up. (The refused readings stay lost.)"
  pause; begin
  need_basics; ensure_page
  vmx alive gwA >/dev/null 2>&1 || { say "  $(start_gateway A)"; STARTED=1; }
  vmx alive sensorsA >/dev/null 2>&1 || say "  $(start_sensors sensorsA $GWA_PORT $NA)"
  # make sure A is flowing first
  wait_for 90 '[ "$(num "$(nlive $NA)")" -ge $((NA - 1)) ]' 'echo "live sensors=$(nlive $NA)"' >/dev/null
  local s0 d0 r0 pg0
  s0=$(sent A); r0=$(refused A); pg0=$(num "$(gwv GW01 batches)")
  say "  before: A sent $s0 batches, page shows $pg0 batches, $(nlive $NA) of $NA sensors live"
  say "  revoking A ..."; REVOKED=1
  local rv; rv=$(ctr bash /tmp/p0-scripts/p1-revoke.sh $MAGIC A | tail -1); say "    $rv"
  case "$rv" in OK:*"list size now 0"*) ok "registry: A revoked ($(echo "$rv" | sed 's/.*took/took/'))";; *) bad "revoke failed: $rv";; esac
  say "  waiting for 2 refused batches of A ..."
  wait_for 120 '[ "$(refused A)" -ge $((r0 + 2)) ]' 'echo "new refused=$(( $(refused A) - r0 ))"'
  local r1; r1=$(refused A)
  [ "$r1" -ge $((r0 + 2)) ] && ok "A's batches are refused after the revoke ($((r1 - r0)) REFUSED lines)" || bad "A is not refused after the revoke"
  say "  one refusal:"; vmx lines gwA REFUSED 50 | tail -1 | sed 's/^/    /'
  say "  waiting for the page to show A's sensors silent (silent after $SILENT s) ..."
  wait_for 150 '[ "$(num "$(nsilent $NA)")" -ge $((NA - 1)) ]' 'echo "silent sensors=$(nsilent $NA) of $NA"'
  local ns; ns=$(num "$(nsilent $NA)")
  [ "$ns" -ge $((NA - 1)) ] && ok "page: $ns of $NA sensors silent" || bad "page: only $ns of $NA sensors silent"
  say "  enrolling A again ..."
  local en; en=$(ctr bash /tmp/p0-scripts/p1-enroll.sh $MAGIC A | tail -1); say "    $en"
  case "$en" in OK:*"list size now 1"*) ok "registry: A enrolled again ($(echo "$en" | sed 's/.*took/took/'))"; REVOKED=0;; *) bad "enrol failed: $en";; esac
  local s1; s1=$(sent A)
  say "  waiting for new batches of A to flow and the sensors to wake up ..."
  wait_for 150 '[ "$(sent A)" -ge $((s1 + 2)) ] && [ "$(num "$(nlive $NA)")" -ge $((NA - 1)) ]' \
    'echo "new sent=$(( $(sent A) - s1 )) live sensors=$(nlive $NA)"'
  local s2 nl pg1; s2=$(sent A); nl=$(num "$(nlive $NA)"); pg1=$(num "$(gwv GW01 batches)")
  [ "$s2" -ge $((s1 + 2)) ] && ok "after re-enrol: $((s2 - s1)) new batches sent" || bad "no new batches after re-enrol"
  [ "$nl" -ge $((NA - 1)) ] && ok "page: $nl of $NA sensors live again, GW01 batches $pg0 -> $pg1" || bad "page: only $nl sensors live again"
  [ "$REVOKED" = 0 ] || restore_registry
  finish 4
  [ $FAILS -eq 0 ]
}

############################################################ step 5
step5() {
  hr "STEP 5: one sensor goes silent (AGRI_003)"
  explain "We restart the sensors of GW01; sensor AGRI_003 stops sending 20 s after the start, the other nine go on." \
          "Look for: after $SILENT s without a new reading from the chain the page marks AGRI_003 'silent' (the alarm)," \
          "the other sensors keep updating. Silence is measured on the server clock, not on the sensor clock."
  pause; begin
  need_basics; ensure_page
  vmx alive gwA >/dev/null 2>&1 || { say "  $(start_gateway A)"; STARTED=1; }
  vmx stop sensorsA 2>/dev/null | sed 's/^/  /'
  say "  $(start_sensors sensorsA $GWA_PORT $NA --silent-sensor AGRI_003 --silent-after 20)"
  say "  waiting for the silent alarm (about 20 s + batch time + $SILENT s) ..."
  wait_for 200 '[ "$(is_silent AGRI_003)" = True ]' 'echo "AGRI_003 silent=$(is_silent AGRI_003) live sensors=$(nlive $NA)"'
  local s3 nl ns
  s3=$(is_silent AGRI_003); nl=$(num "$(nlive $NA)"); ns=$(num "$(nsilent $NA)")
  [ "$s3" = True ] && ok "page: AGRI_003 is silent (alarm)" || bad "page: AGRI_003 is not silent"
  [ "$nl" -ge $((NA - 2)) ] && [ "$ns" -le 2 ] && ok "the other sensors are not silent ($nl live, $ns silent)" || bad "too many silent sensors: $ns silent, $nl live"
  finish 5
  [ $FAILS -eq 0 ]
}

############################################################ step 6
step6() {
  hr "STEP 6: clean stop"
  explain "Sensors, gateways (they write out the last batch first), the page server and the tunnel are stopped." \
          "The registry stays as it was at the start: A enrolled, B not. Logs and outboxes stay in /tmp/demo-logs and $RUN on seedvm."
  pause; begin
  need_basics
  CLEANED=0; cleanup
  local lo r
  lo=$(vmx leftovers); [ -z "$lo" ] && ok "no demo processes left on seedvm" || bad "left: $(echo "$lo" | head -3 | tr '\n' ';')"
  [ "$(vmx list | wc -l | tr -d ' ')" = 0 ] && ok "pid file empty" || bad "pid file not empty"
  if curl -s -m 3 -o /dev/null "$URL/health"; then bad "tunnel/page still answers at $URL"; else ok "tunnel closed, page not reachable"; fi
  if (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then bad "port $PORT still open on the Mac"; else ok "port $PORT closed on the Mac"; fi
  r=$(ctr bash /tmp/p0-scripts/p1-list.sh $MAGIC | tail -1)
  case "$r" in *"A=enrolled B=not-enrolled"*) ok "registry: A enrolled, B not enrolled";; *) bad "registry not in the start state: $r";; esac
  finish 6
  CLEANED=1
  [ $FAILS -eq 0 ]
}

############################################################ main
summary() {
  hr "SUMMARY"
  local i r t
  for i in 0 1 2 3 4 5 6; do eval "r=\$RES$i; t=\$TM$i"; [ "$r" = "-" ] || printf '  step %s  %-9s %4s s\n' "$i" "$r" "$t"; done
}
rc=0
if [ -n "$ONLY" ]; then
  [ "$ONLY" = 0 ] && CLEANED=1
  if [ "$ONLY" != 0 ]; then need_basics; fi
  "step$ONLY" || rc=1
else
  step0 || { say; say "Preflight failed: the demo does not continue. Fix the FAIL lines above (see the hints) and run again."; summary; CLEANED=1; exit 1; }
  for n in 1 2 3 4 5 6; do "step$n" || rc=1; [ $n = 1 ] && [ $rc = 1 ] && { say "page server did not start: stopping"; break; }; done
fi
summary
for i in 0 1 2 3 4 5 6; do eval "r=\$RES$i"; case "$r" in FAIL*) rc=1;; esac; done
exit $rc
