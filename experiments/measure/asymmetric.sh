#!/bin/bash
# Which link's delay does a block feel? Delay on only one of the two joiners at a time.
#
#   ./asymmetric.sh                              SETTINGS="100:0 0:100 100:100 200:0 0:200", 8 minutes each
#   SETTINGS="100:0 0:100" MINUTES=3 ./asymmetric.sh
#
# A setting is <ms on hop 1>:<ms on hop 2>; hop 1 (seedvm2) dials the pools, hop 2 (seedvm4) dials hop 1.
# The delay acts on what each joiner sends. In the first series a block took about 4 times the delay
# to reach hop 2 but only once the delay to hop 1: this shows which link adds what.
# Output: results/asymmetric-<date-time>/propagation.csv (hop1_delay,hop2_delay,node,blocks,median_ms,p95_ms,max_ms)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
POOL=${POOL:-seedvm}; HOP1=${HOP1:-seedvm2}; HOP2=${HOP2:-seedvm4}
SETTINGS=${SETTINGS:-"100:0 0:100 100:100 200:0 0:200"}
MINUTES=${MINUTES:-8}
REPO=cardano-seed-testnet
OUT=${OUT:-$HERE/results/asymmetric-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT/logs"

on() { local vm=$1; shift; ssh -A -o BatchMode=yes "$vm" "cd $REPO && $*" 2> >(grep -v '^\*\*' >&2); }
ip_of() { ssh -o BatchMode=yes "$1" hostname -I 2>/dev/null | cut -d' ' -f1; }
cleanup() { for vm in "$HOP2" "$HOP1"; do on "$vm" "./experiments/join-node/join.sh stop" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

POOL_IP=$(ip_of "$POOL"); HOP1_IP=$(ip_of "$HOP1")
echo "hop1_delay_ms,hop2_delay_ms,node,blocks,median_ms,p95_ms,max_ms" > "$OUT/propagation.csv"
: > "$OUT/blockrate.txt"

cleanup
for vm in "$HOP1" "$HOP2"; do on "$vm" "./experiments/join-node/fetch-chain-files.sh seed@$POOL_IP" >/dev/null; done
on "$HOP1" "DELAY=0 LOSS=0 LISTEN=1 ./experiments/measure/sync-time.sh $POOL_IP" > /dev/null
on "$HOP2" "DELAY=0 LOSS=0 ./experiments/measure/sync-time.sh $HOP1_IP" > /dev/null
echo "both joiners synced"

for setting in $SETTINGS; do
  d1=${setting%%:*}; d2=${setting#*:}
  echo "== hop 1: $d1 ms, hop 2: $d2 ms"
  on "$HOP1" "./experiments/measure/netem.sh set $d1 0"
  on "$HOP2" "./experiments/measure/netem.sh set $d2 0"
  sleep 20                                             # connections settle at the new delay
  AFTER=$(date -u +%Y-%m-%dT%H:%M:%S)    # this machine's clock: the offsets in clock-offsets.py are relative to it
  sleep $((MINUTES * 60))
  LOGS="$OUT/logs/d${d1}_${d2}"; mkdir -p "$LOGS"
  for p in 1 2 3; do on "$POOL" "source scripts/lib.sh && docker exec \$(pool_container $p) cat /var/log/cardano-node.log" > "$LOGS/pool$p.log"; done
  for vm in "$HOP1" "$HOP2"; do ssh -o BatchMode=yes "$vm" "docker logs cardano-joiner 2>&1" > "$LOGS/$vm.log" 2>/dev/null; done
  OFFSETS=$(python3 -I "$HERE/clock-offsets.py" "$POOL" "$HOP1" "$HOP2")
  offset() { awk -F, -v m="$1" '$1 == m { print $2 }' <<< "$OFFSETS"; }
  python3 -I "$HERE/propagation.py" --after "$AFTER" \
      pool1="$LOGS/pool1.log@$(offset "$POOL")" pool2="$LOGS/pool2.log@$(offset "$POOL")" pool3="$LOGS/pool3.log@$(offset "$POOL")" \
      "$HOP1=$LOGS/$HOP1.log@$(offset "$HOP1")" "$HOP2=$LOGS/$HOP2.log@$(offset "$HOP2")" \
      2>> "$OUT/blockrate.txt" | sed "s/^/$d1,$d2,/" >> "$OUT/propagation.csv"
  tail -5 "$OUT/propagation.csv" | sed 's/^/  /'
done
echo "done: $OUT"
