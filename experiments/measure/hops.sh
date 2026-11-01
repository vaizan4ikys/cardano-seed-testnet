#!/bin/bash
# A chain of nodes behind a pool: how do join time, block arrival and transaction latency grow with the
# number of hops? Run from your own machine over SSH, like run-all.sh.
#
#   ./hops.sh                                    HOPS=3, DELAYS="0 50 100"
#   HOPS=6 DELAYS="0 100" IDLE=300 ./hops.sh
#   JOIN_ONLY=1 REPS=3 ./hops.sh                 only the join times, three times
#
# Node k dials node k-1 (node 1 dials pool 1). The nodes sit on three machines; from hop 4 on a machine
# hosts a second node (own container name and port), so a chain of 6 needs only three VMs:
#   hop1 seedvm2:3001   hop2 seedvm4:3001   hop3 seedvm3:3001
#   hop4 seedvm2:3002   hop5 seedvm4:3002   hop6 seedvm3:3002
# Every node gets the delay on what it sends, so beyond the first link the delay acts in both directions
# of a link (data one way, requests the other); the first link, pool to hop 1, is delayed on one side only.
# Per delay: the nodes join one after the other (join time and MB received per hop), then IDLE seconds of
# block arrival samples (keep ../load running so that blocks are full), then transactions at hop 1 and at
# the last hop. Output in results/hops-<date-time>/: join.csv, propagation.csv, tx.csv.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
POOL=${POOL:-seedvm}
HOPS=${HOPS:-3}
DELAYS=${DELAYS:-"0 50 100"}
IDLE=${IDLE:-420}                        # seconds of block samples per delay
REPS=${REPS:-1}                           # repetitions of the whole series
JOIN_ONLY=${JOIN_ONLY:-}                 # 1: only the join times (no block samples, no transactions)
TXS=${TXS:-6}                            # transactions per measured node and delay (one more, not recorded, comes first)
REPO=cardano-seed-testnet
OUT=${OUT:-$HERE/results/hops-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT/logs"

VMS=(seedvm2 seedvm4 seedvm3 seedvm2 seedvm4 seedvm3)         # machine of hop 1..6
PORTS=(3001 3001 3001 3002 3002 3002)                         # port the node publishes on that machine
on() { local vm=$1; shift; ssh -A -o BatchMode=yes "$vm" "cd $REPO && $*" 2> >(grep -v '^\*\*' >&2); }
ip_of() { ssh -o BatchMode=yes "$1" hostname -I 2>/dev/null | cut -d' ' -f1; }
stop_all() { for k in $(seq "$HOPS" -1 1); do on "${VMS[$((k - 1))]}" "docker rm -f hop$k" >/dev/null 2>&1 || true; done; }
trap stop_all EXIT

POOL_IP=$(ip_of "$POOL")
echo "rep,delay_ms,hop,machine,join_seconds,blocks,db_kb,received_mb" > "$OUT/join.csv"
echo "delay_ms,hop,blocks,median_ms,p95_ms,max_ms" > "$OUT/propagation.csv"
echo "delay_ms,hop,block_seconds,mempool_seconds" > "$OUT/tx.csv"
: > "$OUT/blockrate.txt"
{
  echo "date: $(date -u +%FT%TZ)    hops: $HOPS    delays: $DELAYS    idle: $IDLE s"
  echo "chain at start: $(on "$POOL" 'source scripts/lib.sh && tip_of 1')"
  echo "load: $(on "$POOL" './experiments/load/load.sh status' | head -1)"
} | tee "$OUT/setup.txt"

for vm in seedvm2 seedvm4 seedvm3; do on "$vm" "./experiments/join-node/fetch-chain-files.sh seed@$POOL_IP" >/dev/null; done
stop_all

for rep in $(seq "$REPS"); do
for delay in $DELAYS; do
  echo "== repetition $rep, delay $delay ms, $HOPS hops"
  stop_all
  for k in $(seq "$HOPS"); do
    vm=${VMS[$((k - 1))]}; port=${PORTS[$((k - 1))]}
    if [ "$k" = 1 ]; then peer_ip=$POOL_IP; peer_port=3001; else pv=${VMS[$((k - 2))]}; peer_ip=$(ip_of "$pv"); peer_port=${PORTS[$((k - 2))]}; fi
    res=$(on "$vm" "NAME=hop$k HOST_PORT=$port LISTEN=1 DELAY=$delay LOSS=0 TIMEOUT=1800 ./experiments/measure/sync-time.sh $peer_ip $peer_port" || true)
    read -r sec blocks _ dbkb rx <<< "${res:-NA NA NA NA NA}"
    echo "$rep,$delay,$k,$vm,$sec,$blocks,$dbkb,$rx" >> "$OUT/join.csv"
    echo "  hop $k ($vm): ${res:-failed}"
    [ -n "$res" ] || { echo "  hop $k did not sync: the chain stops here"; HOPS_OK=$((k - 1)); break; }
    HOPS_OK=$k
  done

  [ -n "$JOIN_ONLY" ] && continue
  [ "$HOPS_OK" -ge 1 ] || { echo "  no node synced at $delay ms"; continue; }
  AFTER=$(date -u +%Y-%m-%dT%H:%M:%S)    # this machine's clock: clock-offsets.py is relative to it
  sleep "$IDLE"
  tx_nodes=1; [ "$HOPS_OK" -gt 1 ] && tx_nodes="1 $HOPS_OK"
  for i in $(seq 0 "$TXS"); do
    for k in $tx_nodes; do
      vm=${VMS[$((k - 1))]}
      r=$(NAME=hop$k "$HERE/tx-latency.sh" "$vm" 2>> "$OUT/tx-errors.log" || { sleep 8; NAME=hop$k "$HERE/tx-latency.sh" "$vm" 2>> "$OUT/tx-errors.log"; })
      [ "$i" = 0 ] || echo "$delay,$k,$r" >> "$OUT/tx.csv"
    done
  done

  LOGS="$OUT/logs/delay$delay"; mkdir -p "$LOGS"
  for p in 1 2 3; do on "$POOL" "source scripts/lib.sh && docker exec \$(pool_container $p) cat /var/log/cardano-node.log" > "$LOGS/pool$p.log"; done
  for k in $(seq "$HOPS_OK"); do ssh -o BatchMode=yes "${VMS[$((k - 1))]}" "docker logs hop$k 2>&1" > "$LOGS/hop$k.log" 2>/dev/null; done
  OFFSETS=$(python3 -I "$HERE/clock-offsets.py" "$POOL" seedvm2 seedvm4 seedvm3)
  offset() { awk -F, -v m="$1" '$1 == m { print $2 }' <<< "$OFFSETS"; }
  args=(pool1="$LOGS/pool1.log@$(offset "$POOL")" pool2="$LOGS/pool2.log@$(offset "$POOL")" pool3="$LOGS/pool3.log@$(offset "$POOL")")
  for k in $(seq "$HOPS_OK"); do args+=("hop$k=$LOGS/hop$k.log@$(offset "${VMS[$((k - 1))]}")"); done
  python3 -I "$HERE/propagation.py" --after "$AFTER" "${args[@]}" 2>> "$OUT/blockrate.txt" \
    | grep '^hop' | sed "s/^hop/$delay,/" >> "$OUT/propagation.csv"
  tail -$((HOPS_OK + 1)) "$OUT/propagation.csv" | sed 's/^/  /'
done
done
stop_all
trap - EXIT
echo "done: $OUT"
