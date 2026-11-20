#!/bin/bash
# Runs on the chain host (demo.sh calls it over ssh, or directly in local mode). Small process helper:
# start / stop / look at the demo processes (page server, gateways, sensors).
# Logs: /tmp/demo-logs/<name>.log   PID file: /tmp/demo-logs/pids   ("<name> <pid>" per line)
#   remote.sh newrun | rundir              make a new run folder /tmp/demo-run-<time> / print the current one
#   remote.sh start NAME DIR "COMMAND"     run COMMAND in DIR in the background (nohup), log + pid recorded
#   remote.sh stop NAME | stop-all         SIGTERM, wait up to 90 s, then SIGKILL
#   remote.sh alive NAME | list | leftovers
#   remote.sh count NAME REGEX | lines NAME REGEX [N] | deadcount DIR
#   remote.sh ctr | tip | portfree PORT
# Environment: MAGIC (network magic for "tip", default 42).
set -u
LOGDIR=/tmp/demo-logs; PIDFILE=$LOGDIR/pids
mkdir -p "$LOGDIR"; touch "$PIDFILE"
REPO=$HOME/cardano-seed-testnet

# ---- the pid file ----
pid_of() { awk -v n="$1" '$1==n{p=$2} END{print p}' "$PIDFILE"; }
is_alive() { local p; p=$(pid_of "$1"); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
drop() { grep -v "^$1 " "$PIDFILE" > "$PIDFILE.tmp"; mv "$PIDFILE.tmp" "$PIDFILE"; }   # forget a process

# The name of pool 1's container (empty when it is not running).
ctr() { ( . "$REPO/scripts/lib.sh"; pool_container 1 ); }

# stop_one NAME: send TERM now; stop_wait waits for it later (so that many processes stop at the same time)
stop_one() {
  local p; p=$(pid_of "$1"); [ -n "$p" ] && kill -TERM "$p" 2>/dev/null; return 0
}
# stop_wait NAME...: wait until all are gone (90 s), then KILL the rest, then forget them. A gateway sends its
# pending batches for 20 s more and finishes the submit that runs then (up to about 65 s when a block is slow):
# a KILL in the middle of a submit would make the next start report that batch as sent.
stop_wait() {
  local n p i
  for i in $(seq 1 180); do
    local any=0
    for n in "$@"; do is_alive "$n" && any=1; done
    [ $any = 0 ] && break
    sleep 0.5
  done
  for n in "$@"; do
    if is_alive "$n"; then
      p=$(pid_of "$n"); kill -KILL "$p" 2>/dev/null; echo "killed $n (did not stop in 90 s)"
    else
      echo "stopped $n"
    fi
    drop "$n"
  done
}

case "${1:-}" in
  newrun) d=/tmp/demo-run-$(date +%Y%m%d-%H%M%S); mkdir -p "$d"; echo "$d" > "$LOGDIR/rundir"; echo "$d" ;;
  rundir) cat "$LOGDIR/rundir" 2>/dev/null ;;
  start)
    name=$2; dir=$3; cmd=$4
    if is_alive "$name"; then echo "already running: $name pid $(pid_of "$name")"; exit 0; fi
    drop "$name"
    cd "$dir" || { echo "no such directory $dir"; exit 1; }
    nohup bash -c "exec $cmd" > "$LOGDIR/$name.log" 2>&1 < /dev/null &
    pid=$!
    echo "$name $pid" >> "$PIDFILE"
    sleep 0.5
    if kill -0 "$pid" 2>/dev/null; then
      echo "started $name pid $pid"
    else
      echo "$name died at once:"; tail -5 "$LOGDIR/$name.log"; drop "$name"; exit 1
    fi ;;
  stop) stop_one "$2"; stop_wait "$2" ;;
  stop-all)
    names=$(awk '{print $1}' "$PIDFILE" | sort -u)
    # stop order: the sensors first, and they are waited for (a sensor waits up to 10 s for the gateway to confirm
    # its last readings), then the gateways, then the server
    sensors=""; for n in $names; do case $n in sensors*) sensors="$sensors $n";; esac; done
    order=""; for n in $names; do case $n in sensors*|server) ;; *) order="$order $n";; esac; done
    for n in $names; do [ "$n" = server ] && order="$order $n"; done
    for n in $sensors; do stop_one "$n"; done
    [ -n "$sensors" ] && stop_wait $sensors
    for n in $order; do stop_one "$n"; done
    [ -n "$order" ] && stop_wait $order
    : > "$PIDFILE" ;;
  alive) is_alive "$2" ;;
  list)
    while read -r n p; do
      if kill -0 "$p" 2>/dev/null; then echo "$n $p running"; else echo "$n $p dead"; fi
    done < "$PIDFILE" ;;
  leftovers)   # processes of the demo that should not be there (bracket trick: pgrep does not find itself)
    pgrep -af '[g]ateway\.py|[s]ensor\.py|[s]erver\.py|[s]ubmit_contract' | grep -v "remote.sh" || true
    container=$(ctr)
    [ -n "$container" ] && docker exec "$container" pgrep -af '[p]1-batch|[p]1-enroll|[p]1-revoke' 2>/dev/null || true ;;
  count) grep -c -E "$3" "$LOGDIR/$2.log" 2>/dev/null || true ;;
  lines) grep -E "$3" "$LOGDIR/$2.log" 2>/dev/null | head -n "${4:-3}" || true ;;
  deadcount) ls "$2/dead" 2>/dev/null | grep -c '^batch-.*json$' || true ;;
  ctr) ctr ;;
  tip)   # prints "<block> <slot> <syncProgress>" of pool 1's node
    container=$(ctr)
    docker exec "$container" cardano-cli conway query tip --socket-path /node.socket \
        --testnet-magic "${MAGIC:-42}" 2>/dev/null \
      | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["block"], d["slot"], d.get("syncProgress", "?"))' ;;
  portfree) if (exec 3<>/dev/tcp/127.0.0.1/"$2") 2>/dev/null; then echo busy; else echo free; fi ;;
  *) echo "usage: remote.sh newrun|rundir|start|stop|stop-all|alive|list|leftovers|count|lines|deadcount|ctr|tip|portfree"
     exit 1 ;;
esac
