#!/bin/bash
# Runs on the VM that hosts pool 1 (seedvm). Starts and stops the Kupo indexer INSIDE pool 1's container.
# Kupo follows the chain and lets reader.py / server.py ask for the batches by HTTP.
#
# Usage:
#   ./kupo.sh start    copy the binary in if missing, start Kupo (listens on 0.0.0.0:$KUPO_PORT),
#                      wait for /health, print the URL
#   ./kupo.sh stop     stop Kupo (the database stays)
#   ./kupo.sh status   running? Kupo's slot against the node tip
#   ./kupo.sh wipe     stop Kupo and delete its database (needed after a fresh chain)
# Environment (defaults):
#   KUPO_BIN=$HOME/tools/kupo-2.12.0/bin/kupo    Kupo binary on this VM, copied into the container
#   KUPO_PORT=1442                               port Kupo listens on
#   NET=1                                        network number: picks the container and magic (scripts/lib.sh)
#
# start and stop can be repeated: start does nothing if Kupo already runs the way we want it.
# Kupo keeps its database in /tmp/kupo-db inside the container and continues from there after a restart.
# The container's /tmp is lost when the container is removed (then run start again: it rebuilds from the chain).
# demo/fresh.sh and demo/demo.sh call this script and read its output lines.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/scripts/lib.sh"      # sets NET, MAGIC and pool_container

# --- settings ---
KUPO_BIN=${KUPO_BIN:-$HOME/tools/kupo-2.12.0/bin/kupo}
PORT=${KUPO_PORT:-1442}
DB=/tmp/kupo-db               # inside the container
LOG=/tmp/kupo.log             # inside the container

container=$(pool_container 1)
[ -n "$container" ] || { echo "pool 1 of net-$NET is not running"; exit 1; }
# IP of the container (the VM host reaches it directly)
IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$container" | awk '{print $1}')
[ -n "$IP" ] || IP=127.0.0.1
URL=http://$IP:$PORT

# --- helpers ---

# Is a kupo process running in the container?
running() { docker exec "$container" pgrep -x kupo >/dev/null 2>&1; }

# The command line of the running kupo (to see which options it was started with).
cmdline() { docker exec "$container" ps -C kupo -o args= 2>/dev/null | head -1; }

# Does Kupo answer on /health?
health_ok() { curl -s -m 3 -o /dev/null "$URL/health"; }

# Slot of the node tip (empty if the node does not answer).
node_tip_slot() {
  docker exec "$container" cardano-cli conway query tip --socket-path /node.socket --testnet-magic "$MAGIC" \
    2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["slot"])' 2>/dev/null
}

# Slot of Kupo's most recent checkpoint (empty if Kupo does not answer).
kupo_slot() {
  curl -s -m 3 "$URL/health" | awk '/^kupo_most_recent_checkpoint/ {print int($2)}'
}

# --- the four commands ---

# Stop Kupo: ask nicely for up to 30 s, then kill it.
stop_kupo() {
  running || { echo "kupo is not running"; return 0; }
  docker exec "$container" pkill -x kupo
  for i in $(seq 1 30); do running || { echo "kupo stopped"; return 0; }; sleep 1; done
  docker exec "$container" pkill -9 -x kupo
  sleep 1
  running && { echo "kupo did not stop"; return 1; }
  echo "kupo stopped (killed)"
}

# Start Kupo (restart it if it runs with other options), then wait up to 60 s for /health.
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
    if ! docker exec "$container" test -x /tmp/kupo; then
      [ -f "$KUPO_BIN" ] || { echo "binary not found: $KUPO_BIN"; exit 1; }
      echo "copying the kupo binary into $container"
      docker cp "$KUPO_BIN" "$container:/tmp/kupo" && docker exec "$container" chmod +x /tmp/kupo || exit 1
    fi
    # --match '*' --since origin: index every output from the start of the chain
    docker exec -d "$container" sh -c "exec /tmp/kupo --node-socket /node.socket --node-config /cardano/config.json \
      --workdir $DB --match '*' --since origin --host 0.0.0.0 --port $PORT --log-level Warning >> $LOG 2>&1"
    echo "kupo started"
  fi
  for i in $(seq 1 60); do health_ok && break; sleep 1; done
  health_ok || { echo "kupo does not answer on $URL/health (see $LOG in the container)"; exit 1; }
  echo "Kupo URL: $URL"
}

# Print whether Kupo runs, where it is, and how far behind the node it is.
status_kupo() {
  if running; then
    echo "kupo: running ($(cmdline | sed 's/--node-socket [^ ]* //;s/--node-config [^ ]* //'))"
  else
    echo "kupo: NOT running"; return 1
  fi
  health_ok || { echo "kupo: not answering on $URL/health"; return 1; }
  kslot=$(kupo_slot)
  nslot=$(node_tip_slot)
  echo "url: $URL"
  echo "kupo slot: ${kslot:-?}   node tip slot: ${nslot:-?}   behind: $(( ${nslot:-0} - ${kslot:-0} )) slots"
  docker exec "$container" du -sh "$DB" 2>/dev/null | sed 's/^/db size: /'
}

# --- main part ---
case "${1:-}" in
  start) start_kupo ;;
  stop) stop_kupo ;;
  status) status_kupo ;;
  wipe) stop_kupo && docker exec "$container" rm -rf "$DB" && echo "database deleted" ;;
  *) echo "usage: $0 start|stop|status|wipe"; exit 1 ;;
esac
