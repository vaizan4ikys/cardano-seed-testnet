#!/bin/bash
# Catch-up after an outage: for each outage length, a node joins, is cut off for that long, reconnects, and
# is timed until it has caught up (catchup.sh). Run from your own machine; keep ../load running.
#
#   ./outage.sh                                 OUTAGES="60 300 900" on hop 1 (seedvm2) and hop 2 (seedvm4)
#   OUTAGES="60 300" NODES="seedvm2" ./outage.sh
#
# Output: results/outage-<date-time>/outage.csv (node,hops,outage_s,slots_behind,catchup_s,received_mb)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
POOL=${POOL:-seedvm}; HOP1=${HOP1:-seedvm2}; HOP2=${HOP2:-seedvm4}
OUTAGES=${OUTAGES:-"60 300 900"}
NODES=${NODES:-"$HOP1 $HOP2"}
REPO=cardano-seed-testnet
OUT=${OUT:-$HERE/results/outage-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
on() { local vm=$1; shift; ssh -A -o BatchMode=yes "$vm" "cd $REPO && $*" 2> >(grep -v '^\*\*' >&2); }
ip_of() { ssh -o BatchMode=yes "$1" hostname -I 2>/dev/null | cut -d' ' -f1; }
cleanup() { for vm in "$HOP2" "$HOP1"; do on "$vm" "./experiments/join-node/join.sh stop" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT
POOL_IP=$(ip_of "$POOL"); HOP1_IP=$(ip_of "$HOP1")
echo "node,hops,outage_s,slots_behind,catchup_s,received_mb" > "$OUT/outage.csv"
{ echo "date: $(date -u +%FT%TZ)    outages: $OUTAGES    nodes: $NODES"; echo "chain at start: $(on "$POOL" 'source scripts/lib.sh && tip_of 1')"; echo "load: $(on "$POOL" './experiments/load/load.sh status' | head -1)"; } | tee "$OUT/setup.txt"
for vm in "$HOP1" "$HOP2"; do on "$vm" "./experiments/join-node/fetch-chain-files.sh seed@$POOL_IP" >/dev/null; done

for node in $NODES; do
  hops=1; [ "$node" = "$HOP2" ] && hops=2
  for outage in $OUTAGES; do
    echo "== $node (hop $hops): cut off for $outage s"
    cleanup
    on "$HOP1" "LISTEN=1 ./experiments/measure/sync-time.sh $POOL_IP" >/dev/null
    [ "$hops" = 2 ] && on "$HOP2" "./experiments/measure/sync-time.sh $HOP1_IP" >/dev/null
    res=$(on "$node" "TRACE=/tmp/catchup-trace.csv ./experiments/measure/catchup.sh $outage")
    ssh -o BatchMode=yes "$node" cat /tmp/catchup-trace.csv > "$OUT/trace-$node-$outage-$(date +%H%M%S).csv" 2>/dev/null || true   # bytes received after the reconnect, twice a second
    echo "  $res"
    read -r o b c m <<< "$res"
    echo "$node,$hops,$o,$b,$c,$m" >> "$OUT/outage.csv"
  done
done
cleanup; trap - EXIT
echo "done: $OUT"
