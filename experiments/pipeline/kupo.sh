#!/bin/bash
# Runs on the VM that hosts pool 1 (seedvm). Starts and stops the Kupo indexer INSIDE pool 1's container.
#   ./kupo.sh start    copy the binary in if missing, start Kupo (listens on 0.0.0.0:1442), wait for /health, print the URL
#   ./kupo.sh stop     stop Kupo (the database stays)
#   ./kupo.sh status   running? Kupo's slot against the node tip
#   ./kupo.sh wipe     stop Kupo and delete its database (needed after a fresh chain)
# start and stop can be repeated: start does nothing if Kupo already runs the way we want it.
# Kupo keeps its database in /tmp/kupo-db inside the container and continues from there after a restart.
# The container's /tmp is lost when the container is removed (then run start again: it rebuilds from the chain).
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/scripts/lib.sh"

KUPO_BIN=${KUPO_BIN:-$HOME/tools/kupo-2.12.0/bin/kupo}
PORT=${KUPO_PORT:-1442}
DB=/tmp/kupo-db
LOG=/tmp/kupo.log

C=$(pool_container 1)
[ -n "$C" ] || { echo "pool 1 of net-$NET is not running"; exit 1; }
# IP of the container (the VM host reaches it directly)
IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$C" | awk '{print $1}')
[ -n "$IP" ] || IP=127.0.0.1
URL=http://$IP:$PORT

running() { docker exec "$C" pgrep -x kupo >/dev/null 2>&1; }
cmdline() { docker exec "$C" ps -C kupo -o args= 2>/dev/null | head -1; }

health_ok() { curl -s -m 3 -o /dev/null "$URL/health"; }

node_tip_slot() {
  docker exec "$C" cardano-cli conway query tip --socket-path /node.socket --testnet-magic "$MAGIC" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["slot"])' 2>/dev/null
}

kupo_slot() {
  curl -s -m 3 "$URL/health" | awk '/^kupo_most_recent_checkpoint/ {print int($2)}'
}

stop_kupo() {
  running || { echo "kupo is not running"; return 0; }
  docker exec "$C" pkill -x kupo
  for i in $(seq 1 30); do running || { echo "kupo stopped"; return 0; }; sleep 1; done
  docker exec "$C" pkill -9 -x kupo
  sleep 1
  running && { echo "kupo did not stop"; return 1; }
  echo "kupo stopped (killed)"
}

start_kupo() {
  if running; then
    if cmdline | grep -q -- "--host 0.0.0.0" && cmdline | grep -q -- "--port $PORT"; then
      echo "kupo already runs with --host 0.0.0.0"
    else
      echo "kupo runs with other options; restarting it"
      stop_kupo || exit 1
    fi
  fi
  if ! running; then
    if ! docker exec "$C" test -x /tmp/kupo; then
      [ -f "$KUPO_BIN" ] || { echo "binary not found: $KUPO_BIN"; exit 1; }
      echo "copying the kupo binary into $C"
      docker cp "$KUPO_BIN" "$C:/tmp/kupo" && docker exec "$C" chmod +x /tmp/kupo || exit 1
    fi
    docker exec -d "$C" sh -c "exec /tmp/kupo --node-socket /node.socket --node-config /cardano/config.json \
      --workdir $DB --match '*' --since origin --host 0.0.0.0 --port $PORT --log-level Warning >> $LOG 2>&1"
    echo "kupo started"
  fi
  for i in $(seq 1 60); do health_ok && break; sleep 1; done
  health_ok || { echo "kupo does not answer on $URL/health (see $LOG in the container)"; exit 1; }
  echo "Kupo URL: $URL"
}

status_kupo() {
  if running; then
    echo "kupo: running ($(cmdline | sed 's/--node-socket [^ ]* //;s/--node-config [^ ]* //'))"
  else
    echo "kupo: NOT running"; return 1
  fi
  health_ok || { echo "kupo: not answering on $URL/health"; return 1; }
  ks=$(kupo_slot); ns=$(node_tip_slot)
  echo "url: $URL"
  echo "kupo slot: ${ks:-?}   node tip slot: ${ns:-?}   behind: $(( ${ns:-0} - ${ks:-0} )) slots"
  docker exec "$C" du -sh "$DB" 2>/dev/null | sed 's/^/db size: /'
}

case "${1:-}" in
  start) start_kupo ;;
  stop) stop_kupo ;;
  status) status_kupo ;;
  wipe) stop_kupo && docker exec "$C" rm -rf "$DB" && echo "database deleted" ;;
  *) echo "usage: $0 start|stop|status|wipe"; exit 1 ;;
esac
