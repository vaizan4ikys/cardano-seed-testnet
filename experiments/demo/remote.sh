#!/bin/bash
# Runs on seedvm (demo.sh calls it over ssh). Small process helper: start / stop / look at the demo processes.
# Logs: /tmp/demo-logs/<name>.log   PID file: /tmp/demo-logs/pids   ("<name> <pid>" per line)
#   remote.sh newrun | rundir
#   remote.sh start NAME DIR "COMMAND"     run COMMAND in DIR in the background (nohup), log + pid recorded
#   remote.sh stop NAME | stop-all         SIGTERM, wait up to 45 s, then SIGKILL
#   remote.sh alive NAME | list | leftovers
#   remote.sh count NAME REGEX | lines NAME REGEX [N] | deadcount DIR
#   remote.sh ctr | tip | portfree PORT
set -u
L=/tmp/demo-logs; P=$L/pids
mkdir -p "$L"; touch "$P"
pid_of() { awk -v n="$1" '$1==n{p=$2} END{print p}' "$P"; }
is_alive() { local p; p=$(pid_of "$1"); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
drop() { grep -v "^$1 " "$P" > "$P.tmp"; mv "$P.tmp" "$P"; }
REPO=$HOME/cardano-seed-testnet
ctr() { ( . "$REPO/scripts/lib.sh"; pool_container 1 ); }
stop_one() {   # TERM now, wait later (see stop_wait)
  local p; p=$(pid_of "$1"); [ -n "$p" ] && kill -TERM "$p" 2>/dev/null; return 0
}
stop_wait() {  # stop_wait NAME...: wait until all are gone (45 s), then KILL, then forget them
  local n p i
  for i in $(seq 1 90); do
    local any=0
    for n in "$@"; do is_alive "$n" && any=1; done
    [ $any = 0 ] && break
    sleep 0.5
  done
  for n in "$@"; do
    if is_alive "$n"; then p=$(pid_of "$n"); kill -KILL "$p" 2>/dev/null; echo "killed $n (did not stop in 45 s)"; else echo "stopped $n"; fi
    drop "$n"
  done
}
case "${1:-}" in
  newrun) d=/tmp/demo-run-$(date +%Y%m%d-%H%M%S); mkdir -p "$d"; echo "$d" > "$L/rundir"; echo "$d" ;;
  rundir) cat "$L/rundir" 2>/dev/null ;;
  start)
    name=$2; dir=$3; cmd=$4
    if is_alive "$name"; then echo "already running: $name pid $(pid_of "$name")"; exit 0; fi
    drop "$name"
    cd "$dir" || { echo "no such directory $dir"; exit 1; }
    nohup bash -c "exec $cmd" > "$L/$name.log" 2>&1 < /dev/null &
    pid=$!
    echo "$name $pid" >> "$P"
    sleep 0.5
    if kill -0 "$pid" 2>/dev/null; then echo "started $name pid $pid"; else echo "$name died at once:"; tail -5 "$L/$name.log"; drop "$name"; exit 1; fi ;;
  stop) stop_one "$2"; stop_wait "$2" ;;
  stop-all)
    names=$(awk '{print $1}' "$P" | sort -u)
    # sensors first (they feed the gateways), then gateways, then the server
    order=""; for n in $names; do case $n in sensors*) order="$order $n";; esac; done
    for n in $names; do case $n in sensors*|server) ;; *) order="$order $n";; esac; done
    for n in $names; do [ "$n" = server ] && order="$order $n"; done
    for n in $order; do stop_one "$n"; done
    [ -n "$order" ] && stop_wait $order
    : > "$P" ;;
  alive) is_alive "$2" ;;
  list) while read -r n p; do if kill -0 "$p" 2>/dev/null; then echo "$n $p running"; else echo "$n $p dead"; fi; done < "$P" ;;
  leftovers)   # processes of the demo that should not be there (bracket trick: pgrep does not find itself)
    pgrep -af '[g]ateway\.py|[s]ensor\.py|[s]erver\.py|[s]ubmit_contract' | grep -v "remote.sh" || true
    C=$(ctr); [ -n "$C" ] && docker exec "$C" pgrep -af '[p]1-batch|[p]1-enroll|[p]1-revoke' 2>/dev/null || true ;;
  count) grep -c -E "$3" "$L/$2.log" 2>/dev/null || true ;;
  lines) grep -E "$3" "$L/$2.log" 2>/dev/null | head -n "${4:-3}" || true ;;
  deadcount) ls "$2/dead" 2>/dev/null | grep -c '^batch-.*json$' || true ;;
  ctr) ctr ;;
  tip) C=$(ctr); docker exec "$C" cardano-cli conway query tip --socket-path /node.socket --testnet-magic "${MAGIC:-42}" 2>/dev/null \
         | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["block"], d["slot"], d.get("syncProgress", "?"))' ;;
  portfree) if (exec 3<>/dev/tcp/127.0.0.1/"$2") 2>/dev/null; then echo busy; else echo free; fi ;;
  *) echo "usage: remote.sh newrun|rundir|start|stop|stop-all|alive|list|leftovers|count|lines|deadcount|ctr|tip|portfree"; exit 1 ;;
esac
