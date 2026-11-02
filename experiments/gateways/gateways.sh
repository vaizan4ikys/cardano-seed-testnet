#!/bin/bash
# Many gateways, each with its own node and its own funded wallet, submit transactions at the same time from
# different machines. This is the realistic sensor case: the capacity and waiting time seen from the sites.
# Run from your own machine over SSH; the network must run on $POOL (EXPOSE=1) and the load must be off.
#
#   ./gateways.sh                                      6 gateways, TOTALS="100 200 300 400" readings/s, 120 s each
#   GATEWAYS=3 TOTALS="100 200" DURATION=60 ./gateways.sh      a short test
#
# What it does: starts GATEWAYS nodes (gw1..gwN, spread over seedvm2, seedvm3 and seedvm4), each dialling pool 1;
# makes a key for every gateway inside its own container (the key never leaves it); pays every gateway
# FUND lovelace in ONE transaction from the funded genesis key utxo1; then, for every total rate in TOTALS,
# every gateway builds its own chain of signed transactions of B readings, and all of them start submitting at
# the same moment through their own node. A transaction is timed from its planned send time until it is in a
# block, read from the gateway's own node. aggregate.py adds up the gateways.
# Compare with the one-place capacity test in ../saturation (about 280 to 330 readings/s on the 5 s testnet).
# Output: results/gateways-<date-time>/steps.csv, steps-R<total>-gw<k>.csv, txs-R<total>-gw<k>.csv, setup.txt
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
POOL=${POOL:-seedvm}
GATEWAYS=${GATEWAYS:-6}
B=${B:-100}                                   # readings per transaction
TOTALS=${TOTALS:-"100 200 300 400"}           # readings per second, all gateways together
DURATION=${DURATION:-120}
FUND=${FUND:-100000000}                       # lovelace per gateway (100 ADA)
MAGIC=${MAGIC:-42}
REPO=cardano-seed-testnet
VMS=(seedvm2 seedvm3 seedvm4)
OUT=${OUT:-$HERE/results/gateways-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"

on() { local vm=$1; shift; ssh -A -o BatchMode=yes "$vm" "cd $REPO && $*" 2> >(grep -v '^\*\*' >&2); }
ip_of() { ssh -o BatchMode=yes "$1" hostname -I 2>/dev/null | cut -d' ' -f1; }
vm_of() { echo "${VMS[$(( ($1 - 1) % ${#VMS[@]} ))]}"; }
stop_all() { for vm in "${VMS[@]}"; do on "$vm" 'docker rm -f $(docker ps -aq --filter name=gw) >/dev/null 2>&1; true' >/dev/null 2>&1 || true; done; }
trap stop_all EXIT
mempool() { on "$POOL" 'source scripts/lib.sh && docker exec $(pool_container 1) cardano-cli conway query tx-mempool info --socket-path /node.socket --testnet-magic $MAGIC' | jq -r .numberOfTxs; }

[ "$(on "$POOL" './experiments/load/load.sh status' | head -1)" = running ] && { echo "the load is running: stop it first"; exit 1; }
POOL_IP=$(ip_of "$POOL")
{ echo "date: $(date -u +%FT%TZ)    gateways: $GATEWAYS    readings per tx: $B    totals: $TOTALS    duration: $DURATION s"
  echo "chain at start: $(on "$POOL" 'source scripts/lib.sh && tip_of 1')"; } | tee "$OUT/setup.txt"

# machines: scripts and chain files
for vm in "${VMS[@]}"; do
  rsync -a --exclude results "$ROOT/experiments/" "${vm}:$REPO/experiments/" 2> >(grep -v '^\*\*' >&2)
  on "$vm" "./experiments/join-node/fetch-chain-files.sh seed@$POOL_IP" >/dev/null
done
stop_all

# 1. the gateway nodes
for k in $(seq "$GATEWAYS"); do
  on "$(vm_of "$k")" "NAME=gw$k TIMEOUT=600 ./experiments/measure/sync-time.sh $POOL_IP 3001" >/dev/null || { echo "gw$k did not sync"; exit 1; }
done
echo "$GATEWAYS gateway nodes are synced"

# 2. a key for every gateway, made inside its container; only the address comes out
ADDRS=()
for k in $(seq "$GATEWAYS"); do
  vm=$(vm_of "$k")
  addr=$(on "$vm" "docker exec gw$k bash -c 'mkdir -p /tmp/gw && cardano-cli conway address key-gen --verification-key-file /tmp/gw/payment.vkey --signing-key-file /tmp/gw/payment.skey && cardano-cli conway address build --payment-verification-key-file /tmp/gw/payment.vkey --testnet-magic $MAGIC'")
  ADDRS+=("$addr")
done
printf '%s\n' "${ADDRS[@]}" > "$OUT/addresses.txt"

# 3. one funding transaction
on "$POOL" "source scripts/lib.sh && docker exec -i -e LOVELACE=$FUND \$(require_pool 1) bash -s -- $MAGIC ${ADDRS[*]}" < "$HERE/in-container/gw-fund.sh" | tee -a "$OUT/setup.txt"
for k in $(seq "$GATEWAYS"); do   # every gateway sees its money through its own node
  vm=$(vm_of "$k")
  for _ in $(seq 60); do
    on "$vm" "docker exec gw$k cardano-cli conway query utxo --address ${ADDRS[$((k - 1))]} --output-json --testnet-magic $MAGIC --socket-path /node.socket" 2>/dev/null | grep -q lovelace && break; sleep 2
  done
done
for k in $(seq "$GATEWAYS"); do
  vm=$(vm_of "$k")
  on "$vm" "docker exec gw$k mkdir -p /tmp/sat-scripts && docker cp experiments/saturation/in-container/. gw$k:/tmp/sat-scripts/" >/dev/null
done

# 4. the steps
for total in $TOTALS; do
  rate=$(awk -v t="$total" -v b="$B" -v g="$GATEWAYS" 'BEGIN { printf "%.4f", t / (b * g) }')       # transactions per second per gateway
  n=$(awk -v r="$rate" -v d="$DURATION" 'BEGIN { printf "%d", r * d + 1 }')
  echo "== $total readings/s in total: $GATEWAYS gateways x $rate tx/s x $B readings, $DURATION s"
  START=$(( $(on "$POOL" 'date +%s') + 30 + n / 2 ))        # the same start for all, after they have built their transactions (about 20 per second)
  pids=()
  for k in $(seq "$GATEWAYS"); do
    vm=$(vm_of "$k")
    on "$vm" "docker exec -e MAGIC=$MAGIC -e B=$B -e RATE=$rate -e DURATION=$DURATION -e LANES=1 -e KEY=/tmp/gw/payment -e START_AT=$START gw$k bash /tmp/sat-scripts/sat-step.sh" > "$OUT/.step-$total-$k" 2>> "$OUT/errors.log" &
    pids+=($!)
  done
  wait "${pids[@]}" || true
  for k in $(seq "$GATEWAYS"); do
    vm=$(vm_of "$k")
    tail -2 "$OUT/.step-$total-$k" > "$OUT/steps-R$total-gw$k.csv"
    on "$vm" "docker exec gw$k cat /tmp/sat/step/txs.csv" > "$OUT/txs-R$total-gw$k.csv"
    on "$vm" "docker exec gw$k cat /tmp/sat/step/rejects.log" > "$OUT/rejects-R$total-gw$k.log" 2>/dev/null || true
    [ -s "$OUT/rejects-R$total-gw$k.log" ] || rm -f "$OUT/rejects-R$total-gw$k.log"
    [ "$(tail -2 "$OUT/steps-R$total-gw$k.csv" | tail -1 | cut -d, -f13)" = 0 ] || on "$vm" "docker logs gw$k 2>&1 | tail -300" > "$OUT/nodelog-R$total-gw$k.log"
  done
  rm -f "$OUT"/.step-*
  for _ in $(seq 120); do [ "$(mempool)" = 0 ] && break; sleep 5; done
  sleep 20
done
python3 -I "$HERE/aggregate.py" "$OUT"
echo "done: $OUT"
