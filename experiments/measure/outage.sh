#!/bin/bash
# Catch-up after an outage: for each outage length, a node joins, is cut off for that long, reconnects, and
# is timed until it has caught up (catchup.sh). Runs on your own machine (the Mac) and drives the VMs over
# ssh; keep ../load running.
#
# Usage:
#   ./outage.sh                                 OUTAGES="60 300 900" on hop 1 and hop 2
#   OUTAGES="60 300" NODES="seedvm2" ./outage.sh
#
# Environment (default):
#   POOL     the VM that runs the pools                    (POOL_HOST from scripts/config.sh)
#   HOP1     joiner that dials the pools                   (VM2 from scripts/config.sh)
#   HOP2     joiner that dials HOP1                        (VM4 from scripts/config.sh)
#   OUTAGES  outage lengths in seconds                     ("60 300 900")
#   NODES    the nodes to cut off: HOP1 and/or HOP2        ("$HOP1 $HOP2")
#   OUT      result folder                                 (results/outage-<date-time> next to this script)
#
# Output: results/outage-<date-time>/outage.csv (node,hops,outage_s,slots_behind,catchup_s,received_mb),
# trace-<node>-<outage>-<time>.csv (bytes received after the reconnect, twice a second), setup.txt
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../../scripts/config.sh"            # POOL_HOST, VM2, VM4, REPO

POOL=${POOL:-$POOL_HOST}; HOP1=${HOP1:-$VM2}; HOP2=${HOP2:-$VM4}
OUTAGES=${OUTAGES:-"60 300 900"}
NODES=${NODES:-"$HOP1 $HOP2"}
OUT=${OUT:-$HERE/results/outage-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"

# --- helpers (every ssh call hides the "**" banner lines of the VM) ---

# run a command in the repository folder on a VM ("-A": the VM may need your key to reach the pool)
on() { local vm=$1; shift; ssh -A -o BatchMode=yes "$vm" "cd $REPO && $*" 2> >(grep -v '^\*\*' >&2); }

# first IP address of a VM
ip_of() { ssh -o BatchMode=yes "$1" hostname -I 2>/dev/null | cut -d' ' -f1; }

# remove the joiners of both hops
cleanup() { for vm in "$HOP2" "$HOP1"; do on "$vm" "./experiments/join-node/join.sh stop" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

POOL_IP=$(ip_of "$POOL"); HOP1_IP=$(ip_of "$HOP1")
echo "node,hops,outage_s,slots_behind,catchup_s,received_mb" > "$OUT/outage.csv"
{
  echo "date: $(date -u +%FT%TZ)    outages: $OUTAGES    nodes: $NODES"
  echo "chain at start: $(on "$POOL" 'source scripts/lib.sh && tip_of 1')"
  echo "load: $(on "$POOL" './experiments/load/load.sh status' | head -1)"
} | tee "$OUT/setup.txt"
for vm in "$HOP1" "$HOP2"; do on "$vm" "./experiments/join-node/fetch-chain-files.sh seed@$POOL_IP" >/dev/null; done

for node in $NODES; do
  hops=1; [ "$node" = "$HOP2" ] && hops=2
  for outage in $OUTAGES; do
    echo "== $node (hop $hops): cut off for $outage s"
    cleanup
    on "$HOP1" "LISTEN=1 ./experiments/measure/sync-time.sh $POOL_IP" >/dev/null
    [ "$hops" = 2 ] && on "$HOP2" "./experiments/measure/sync-time.sh $HOP1_IP" >/dev/null
    res=$(on "$node" "TRACE=/tmp/catchup-trace.csv ./experiments/measure/catchup.sh $outage")
    ssh -o BatchMode=yes "$node" cat /tmp/catchup-trace.csv > "$OUT/trace-$node-$outage-$(date +%H%M%S).csv" 2>/dev/null || true
    echo "  $res"
    read -r o b c m <<< "$res"
    echo "$node,$hops,$o,$b,$c,$m" >> "$OUT/outage.csv"
  done
done
cleanup; trap - EXIT
echo "done: $OUT"
