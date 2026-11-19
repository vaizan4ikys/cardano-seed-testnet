#!/bin/bash
# Which link's delay does a block feel? Delay on only one of the two joiners at a time.
# Runs on your own machine (the Mac) and drives the VMs over ssh, like run-all.sh.
#
# Usage:
#   ./asymmetric.sh                              SETTINGS="100:0 0:100 100:100 200:0 0:200", 8 minutes each
#   SETTINGS="100:0 0:100" MINUTES=3 ./asymmetric.sh
#
# Environment (default):
#   POOL      the VM that runs the pools                 (POOL_HOST from scripts/config.sh)
#   HOP1      joiner that dials the pools                (VM2 from scripts/config.sh)
#   HOP2      joiner that dials HOP1                     (VM4 from scripts/config.sh)
#   SETTINGS  "<ms on hop 1>:<ms on hop 2> ..."          ("100:0 0:100 100:100 200:0 0:200")
#   MINUTES   minutes of block samples per setting       (8)
#   OUT       result folder                              (results/asymmetric-<date-time> next to this script)
#
# The delay acts on what each joiner sends. In the first series a block took about 4 times the delay to
# reach hop 2 but only once the delay to hop 1: this shows which link adds what.
# Output: results/asymmetric-<date-time>/propagation.csv (hop1_delay,hop2_delay,node,blocks,median_ms,p95_ms,max_ms)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../../scripts/config.sh"            # POOL_HOST, VM2, VM4, REPO

POOL=${POOL:-$POOL_HOST}; HOP1=${HOP1:-$VM2}; HOP2=${HOP2:-$VM4}
SETTINGS=${SETTINGS:-"100:0 0:100 100:100 200:0 0:200"}
MINUTES=${MINUTES:-8}
OUT=${OUT:-$HERE/results/asymmetric-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT/logs"

# --- helpers (every ssh call hides the "**" banner lines of the VM) ---

# run a command in the repository folder on a VM ("-A": the VM may need your key to reach the pool)
on() { local vm=$1; shift; ssh -A -o BatchMode=yes "$vm" "cd $REPO && $*" 2> >(grep -v '^\*\*' >&2); }

# first IP address of a VM
ip_of() { ssh -o BatchMode=yes "$1" hostname -I 2>/dev/null | cut -d' ' -f1; }

# the node log of pool $1 (1, 2 or 3)
pool_log() { on "$POOL" "source scripts/lib.sh && docker exec \$(pool_container $1) cat /var/log/cardano-node.log"; }

# remove the joiners of both hops
cleanup() { for vm in "$HOP2" "$HOP1"; do on "$vm" "./experiments/join-node/join.sh stop" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

# --- start: both joiners synced, no delay yet ---
POOL_IP=$(ip_of "$POOL"); HOP1_IP=$(ip_of "$HOP1")
echo "hop1_delay_ms,hop2_delay_ms,node,blocks,median_ms,p95_ms,max_ms" > "$OUT/propagation.csv"
: > "$OUT/blockrate.txt"

cleanup
for vm in "$HOP1" "$HOP2"; do on "$vm" "./experiments/join-node/fetch-chain-files.sh seed@$POOL_IP" >/dev/null; done
on "$HOP1" "DELAY=0 LOSS=0 LISTEN=1 ./experiments/measure/sync-time.sh $POOL_IP" > /dev/null
on "$HOP2" "DELAY=0 LOSS=0 ./experiments/measure/sync-time.sh $HOP1_IP" > /dev/null
echo "both joiners synced"

# --- one block-sampling window per setting ---
for setting in $SETTINGS; do
  d1=${setting%%:*}; d2=${setting#*:}
  echo "== hop 1: $d1 ms, hop 2: $d2 ms"
  on "$HOP1" "./experiments/measure/netem.sh set $d1 0"
  on "$HOP2" "./experiments/measure/netem.sh set $d2 0"
  sleep 20                                             # connections settle at the new delay
  AFTER=$(date -u +%Y-%m-%dT%H:%M:%S)    # this machine's clock: the offsets in clock-offsets.py are relative to it
  sleep $((MINUTES * 60))

  # the logs of the three pools and the two joiners
  LOGS="$OUT/logs/d${d1}_${d2}"; mkdir -p "$LOGS"
  for p in 1 2 3; do pool_log $p > "$LOGS/pool$p.log"; done
  for vm in "$HOP1" "$HOP2"; do ssh -o BatchMode=yes "$vm" "docker logs cardano-joiner 2>&1" > "$LOGS/$vm.log" 2>/dev/null; done

  # put the logs of all machines on one timeline
  OFFSETS=$(python3 -I "$HERE/clock-offsets.py" "$POOL" "$HOP1" "$HOP2")
  offset() { awk -F, -v m="$1" '$1 == m { print $2 }' <<< "$OFFSETS"; }
  python3 -I "$HERE/propagation.py" --after "$AFTER" \
      pool1="$LOGS/pool1.log@$(offset "$POOL")" pool2="$LOGS/pool2.log@$(offset "$POOL")" \
      pool3="$LOGS/pool3.log@$(offset "$POOL")" \
      "$HOP1=$LOGS/$HOP1.log@$(offset "$HOP1")" "$HOP2=$LOGS/$HOP2.log@$(offset "$HOP2")" \
      2>> "$OUT/blockrate.txt" | sed "s/^/$d1,$d2,/" >> "$OUT/propagation.csv"
  tail -5 "$OUT/propagation.csv" | sed 's/^/  /'
done
echo "done: $OUT"
