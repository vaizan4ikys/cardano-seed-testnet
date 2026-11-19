#!/bin/bash
# Many gateways, each with its own node and its own funded wallet, submit transactions at the same time from
# different machines. This is the realistic sensor case: the capacity and waiting time seen from the sites.
# Runs on your own machine (the Mac) and drives the lab VMs over ssh; the network must run on $POOL
# (started with EXPOSE=1) and the load must be off.
#
# What it does: starts GATEWAYS nodes (gw1..gwN, spread over the VMs), each dialling pool 1 (or a relay);
# makes a key for every gateway inside its own container (the key never leaves it); pays every gateway
# FUND lovelace in ONE transaction from the funded genesis key utxo1; then, for every total rate in TOTALS,
# every gateway builds its own chain of signed transactions of B readings, and all of them start submitting at
# the same moment through their own node. A transaction is timed from its planned send time until it is in a
# block, read from the gateway's own node. aggregate.py adds up the gateways.
# Compare with the one-place capacity test in ../saturation (about 280 to 330 readings/s on the 5 s testnet).
# Output: results/gateways-<date-time>/steps.csv, steps-R<total>-gw<k>.csv, txs-R<total>-gw<k>.csv, setup.txt
#
# Usage:
#   ./gateways.sh                                         6 gateways, TOTALS="100 200 300 400" readings/s, 120 s each
#   GATEWAYS=3 TOTALS="100 200" DURATION=60 ./gateways.sh   a short test
#
# Environment (default):
#   POOL      the VM that runs the pools                 (POOL_HOST from scripts/config.sh)
#   GATEWAYS  number of gateways                         (6)
#   B         readings per transaction                   (100)
#   TOTALS    readings per second, all gateways together; one step per value  ("100 200 300 400")
#   DURATION  seconds of submitting per step             (120)
#   FUND      lovelace paid to every gateway             (100000000 = 100 ADA)
#   DEPTHS    hops behind the pool of gateway 1, 2, 3 ... (repeats): 1 = dials the pool,
#             3 = pool -> relay -> relay -> gateway; at most 4  (1)
#   DELAY     ms added to what every relay and gateway sends   (0)
#   MAGIC     network magic                              (42)
#   OUT       result folder                              (results/gateways-<date-time> next to this script)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
source "$ROOT/scripts/config.sh"                 # POOL_HOST, VM2, VM3, VM4, REPO

POOL=${POOL:-$POOL_HOST}
GATEWAYS=${GATEWAYS:-6}
B=${B:-100}
TOTALS=${TOTALS:-"100 200 300 400"}
DURATION=${DURATION:-120}
FUND=${FUND:-100000000}
DEPTHS=${DEPTHS:-1}
DELAY=${DELAY:-0}
MAGIC=${MAGIC:-42}
OUT=${OUT:-$HERE/results/gateways-$(date +%Y%m%d-%H%M%S)}

VMS=("$VM2" "$VM3" "$VM4")               # gateway k runs on VMS[(k-1) mod 3]
RVMS=("$VM2" "$VM4" "$VM3")              # machine of relay 1, 2, 3 (the same layout as ../measure/hops.sh)
DEP=($DEPTHS)

# the deepest gateway decides how many relays are needed
MAXD=1; for d in "${DEP[@]}"; do [ "$d" -gt "$MAXD" ] && MAXD=$d; done
[ "$MAXD" -le 4 ] || { echo "at most 4 hops (3 relays)"; exit 1; }
mkdir -p "$OUT"

# --- helpers (every ssh call hides the "**" banner lines of the VM) ---

# run a command in the repository folder on a VM:  on <vm> <command>
on() { local vm=$1; shift; ssh -A -o BatchMode=yes "$vm" "cd $REPO && $*" 2> >(grep -v '^\*\*' >&2); }

# first IP address of a VM
ip_of() { ssh -o BatchMode=yes "$1" hostname -I 2>/dev/null | cut -d' ' -f1; }

# the VM that runs gateway k
vm_of() { echo "${VMS[$(( ($1 - 1) % ${#VMS[@]} ))]}"; }

# how many hops gateway k sits behind the pool
depth_of() { echo "${DEP[$(( ($1 - 1) % ${#DEP[@]} ))]}"; }

# remove all gateway and relay containers on all VMs (also runs when the script ends)
stop_all() {
  for vm in "${VMS[@]}"; do
    on "$vm" 'docker rm -f $(docker ps -aq --filter name=gw) $(docker ps -aq --filter name=hop) >/dev/null 2>&1; true' \
      >/dev/null 2>&1 || true
  done
}
trap stop_all EXIT

# number of transactions waiting in pool 1's mempool
mempool() {
  on "$POOL" 'source scripts/lib.sh && docker exec $(pool_container 1) cardano-cli conway query tx-mempool info --socket-path /node.socket --testnet-magic $MAGIC' \
    | jq -r .numberOfTxs
}

# the "lost" value (column 13) of the summary row, the last line of a gateway's steps file
lost_of() { tail -2 "$1" | tail -1 | cut -d, -f13; }

# --- the load must be off ---
[ "$(on "$POOL" './experiments/load/load.sh status' | head -1)" = running ] && {
  echo "the load is running: stop it first"; exit 1
}
POOL_IP=$(ip_of "$POOL")
{
  echo "date: $(date -u +%FT%TZ)    gateways: $GATEWAYS    readings per tx: $B    totals: $TOTALS" \
       "   duration: $DURATION s    depths: $DEPTHS    delay: $DELAY ms"
  echo "chain at start: $(on "$POOL" 'source scripts/lib.sh && tip_of 1')"
} | tee "$OUT/setup.txt"

# --- 0. machines: scripts and chain files ---
for vm in "${VMS[@]}"; do
  rsync -a --exclude results "$ROOT/experiments/" "${vm}:$REPO/experiments/" 2> >(grep -v '^\*\*' >&2)
  on "$vm" "./experiments/join-node/fetch-chain-files.sh seed@$POOL_IP" >/dev/null
done
stop_all

# --- 1. the relays (a chain behind pool 1, only if some gateway sits deeper than hop 1), then the gateway nodes ---
for ((j = 1; j < MAXD; j++)); do
  rvm=${RVMS[$((j - 1))]}
  if [ "$j" = 1 ]; then peer=$POOL_IP; else peer=$(ip_of "${RVMS[$((j - 2))]}"); fi
  on "$rvm" "NAME=hop$j LISTEN=1 DELAY=$DELAY TIMEOUT=600 ./experiments/measure/sync-time.sh $peer 3001" >/dev/null \
    || { echo "relay hop$j did not sync"; exit 1; }
done
[ "$MAXD" -gt 1 ] && echo "$((MAXD - 1)) relays are synced"
: > "$OUT/depths.txt"                             # "<gateway> <depth> <vm>" per line, read by perdepth.py
for k in $(seq "$GATEWAYS"); do
  d=$(depth_of "$k")
  if [ "$d" = 1 ]; then peer=$POOL_IP; else peer=$(ip_of "${RVMS[$((d - 2))]}"); fi
  echo "$k $d $(vm_of "$k")" >> "$OUT/depths.txt"
  on "$(vm_of "$k")" "NAME=gw$k DELAY=$DELAY TIMEOUT=600 ./experiments/measure/sync-time.sh $peer 3001" >/dev/null \
    || { echo "gw$k did not sync"; exit 1; }
done
echo "$GATEWAYS gateway nodes are synced"

# --- 2. a key for every gateway, made inside its container; only the address comes out ---
KEYGEN="mkdir -p /tmp/gw"
KEYGEN="$KEYGEN && cardano-cli conway address key-gen --verification-key-file /tmp/gw/payment.vkey"
KEYGEN="$KEYGEN --signing-key-file /tmp/gw/payment.skey"
KEYGEN="$KEYGEN && cardano-cli conway address build --payment-verification-key-file /tmp/gw/payment.vkey"
KEYGEN="$KEYGEN --testnet-magic $MAGIC"
ADDRS=()
for k in $(seq "$GATEWAYS"); do
  addr=$(on "$(vm_of "$k")" "docker exec gw$k bash -c '$KEYGEN'")
  ADDRS+=("$addr")
done
printf '%s\n' "${ADDRS[@]}" > "$OUT/addresses.txt"

# --- 3. one funding transaction ---
on "$POOL" "source scripts/lib.sh && docker exec -i -e LOVELACE=$FUND \$(require_pool 1) bash -s -- $MAGIC ${ADDRS[*]}" \
  < "$HERE/in-container/gw-fund.sh" | tee -a "$OUT/setup.txt"
for k in $(seq "$GATEWAYS"); do   # every gateway sees its money through its own node
  vm=$(vm_of "$k")
  query_funds="docker exec gw$k cardano-cli conway query utxo --address ${ADDRS[$((k - 1))]} --output-json"
  query_funds="$query_funds --testnet-magic $MAGIC --socket-path /node.socket"
  for _ in $(seq 60); do
    on "$vm" "$query_funds" 2>/dev/null | grep -q lovelace && break; sleep 2
  done
done
# the step script of ../saturation goes into every gateway container
for k in $(seq "$GATEWAYS"); do
  on "$(vm_of "$k")" \
    "docker exec gw$k mkdir -p /tmp/sat-scripts && docker cp experiments/saturation/in-container/. gw$k:/tmp/sat-scripts/" \
    >/dev/null
done

# --- 4. the steps ---
for total in $TOTALS; do
  rate=$(awk -v t="$total" -v b="$B" -v g="$GATEWAYS" 'BEGIN { printf "%.4f", t / (b * g) }')   # tx/s per gateway
  n=$(awk -v r="$rate" -v d="$DURATION" 'BEGIN { printf "%d", r * d + 1 }')                     # tx per gateway
  echo "== $total readings/s in total: $GATEWAYS gateways x $rate tx/s x $B readings, $DURATION s"
  # the same start for all, after they have built their transactions (about 20 per second)
  START=$(( $(on "$POOL" 'date +%s') + 30 + n / 2 ))
  step_env="-e MAGIC=$MAGIC -e B=$B -e RATE=$rate -e DURATION=$DURATION -e LANES=1"
  step_env="$step_env -e KEY=/tmp/gw/payment -e START_AT=$START"
  pids=()
  for k in $(seq "$GATEWAYS"); do
    on "$(vm_of "$k")" "docker exec $step_env gw$k bash /tmp/sat-scripts/sat-step.sh" \
      > "$OUT/.step-$total-$k" 2>> "$OUT/errors.log" &
    pids+=($!)
  done
  wait "${pids[@]}" || true

  # collect each gateway's results (the node log too if it lost transactions)
  for k in $(seq "$GATEWAYS"); do
    vm=$(vm_of "$k")
    tail -2 "$OUT/.step-$total-$k" > "$OUT/steps-R$total-gw$k.csv"
    on "$vm" "docker exec gw$k cat /tmp/sat/step/txs.csv" > "$OUT/txs-R$total-gw$k.csv"
    on "$vm" "docker exec gw$k cat /tmp/sat/step/rejects.log" > "$OUT/rejects-R$total-gw$k.log" 2>/dev/null || true
    [ -s "$OUT/rejects-R$total-gw$k.log" ] || rm -f "$OUT/rejects-R$total-gw$k.log"
    [ "$(lost_of "$OUT/steps-R$total-gw$k.csv")" = 0 ] \
      || on "$vm" "docker logs gw$k 2>&1 | tail -300" > "$OUT/nodelog-R$total-gw$k.log"
  done
  rm -f "$OUT"/.step-*

  # let the mempool empty before the next step
  for _ in $(seq 120); do [ "$(mempool)" = 0 ] && break; sleep 5; done
  sleep 20
done
python3 -I "$HERE/aggregate.py" "$OUT"
echo "done: $OUT"
