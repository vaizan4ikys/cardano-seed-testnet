#!/bin/bash
# Failure tests, run ON the machine that hosts the network (seedvm): stop pools, cut a pool off the network,
# and watch the chain keep going and heal. Every scenario is:  <kind>:<seconds>
#
#   stop1:300   stop pool 3 for 300 s       (2 of 3 pools keep forging)
#   stop2:300   stop pools 2 and 3 for 300 s (pool 1 alone keeps forging)
#   cut3:180    cut pool 3 off the network (its SEED router stops) for 180 s; pool 3 keeps forging its own chain
#
#   ./failures.sh                         SCENARIOS="stop1:300 stop2:300 cut3:60 cut3:180 cut3:360 cut3:900"
#   SCENARIOS="cut3:30" ./failures.sh     a short test
#
# Every 10 s the block number and hash of every running pool is written to timeline.csv. At the end of an
# outage everything is switched back on and we time how long it takes until the three pools have the same tip.
# With k = 60 a pool that forged more than 60 blocks of its own fork cannot go back to the other chain: such a
# cut (about 15 minutes for a pool with a third of the stake) does not heal. The container names and the
# router come from scripts/lib.sh.
# Output: ~/failures-<date-time>/{timeline.csv,summary.csv}
set -uo pipefail
cd "$(dirname "$0")/../.." && source scripts/lib.sh
SCENARIOS=${SCENARIOS:-"stop1:300 stop2:300 cut3:60 cut3:180 cut3:360 cut3:900"}
HEAL_TIMEOUT=${HEAL_TIMEOUT:-900}
OUT=${OUT:-$HOME/failures-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"

# "<block> <short hash>" of pool N, or "NA NA" if it is not running
tip() {
  local c; c=$(pool_container "$1")
  [ -n "$c" ] || { echo "NA NA"; return; }
  timeout 8 docker exec "$c" cardano-cli query tip --socket-path "$SOCKET" --testnet-magic "$MAGIC" 2>/dev/null \
    | jq -r '"\(.block) \(.hash[0:6])"' 2>/dev/null || echo "NA NA"
}
sample() {   # scenario phase
  local t=$(date -u +%T) row="$1,$2,$(date -u +%T)"
  for n in 1 2 3; do row="$row,$(tip $n | tr ' ' ',')"; done
  echo "$row" >> "$OUT/timeline.csv"; echo "$row"
}
same_tip() { local a b c; a=$(tip 1); b=$(tip 2); c=$(tip 3); [ "$a" = "$b" ] && [ "$b" = "$c" ] && [[ "$a" != NA* ]]; }
restore() {
  for n in 1 2 3; do
    r=$(docker ps -a --format '{{.Names}}' | grep "^as$((FIRST_AS + n - 1))r-router0-" | head -1); [ -n "$r" ] && docker start "$r" >/dev/null 2>&1
    p=$(docker ps -a --format '{{.Names}}' | grep "^as$((FIRST_AS + n - 1))h-$LABEL-Pool-$n-" | head -1); [ -n "$p" ] && docker start "$p" >/dev/null 2>&1
  done
}
trap restore EXIT

echo "scenario,phase,time_utc,pool1_block,pool1_hash,pool2_block,pool2_hash,pool3_block,pool3_hash" > "$OUT/timeline.csv"
echo "scenario,outage_s,blocks_per_min_during,blocks_per_min_before,max_block_gap_at_restore,heal_seconds,healed" > "$OUT/summary.csv"
same_tip || { echo "pools do not agree at the start: stopping"; exit 1; }

for sc in $SCENARIOS; do
  kind=${sc%%:*}; secs=${sc#*:}
  echo "== $sc"
  # baseline: 60 s
  b0=$(tip 1 | cut -d' ' -f1); t0=$(date +%s); sleep 60; b1=$(tip 1 | cut -d' ' -f1); t1=$(date +%s)
  before=$(awk -v b=$((b1 - b0)) -v s=$((t1 - t0)) 'BEGIN { printf "%.1f", b * 60 / s }')
  # outage
  case $kind in
    stop1) docker stop "$(pool_container 3)" >/dev/null; alive=1 ;;
    stop2) docker stop "$(pool_container 3)" "$(pool_container 2)" >/dev/null; alive=1 ;;
    cut3)  docker stop "$(pool_router 3)" >/dev/null; alive=1 ;;
    *) echo "unknown scenario $sc"; continue ;;
  esac
  a0=$(tip $alive | cut -d' ' -f1); s0=$(date +%s); end=$((s0 + secs))
  while [ "$(date +%s)" -lt "$end" ]; do sample "$sc" outage; sleep 10; done
  a1=$(tip $alive | cut -d' ' -f1); s1=$(date +%s)
  during=$(awk -v b=$((a1 - a0)) -v s=$((s1 - s0)) 'BEGIN { printf "%.1f", b * 60 / s }')
  # gap between the highest and the lowest running pool at the moment of the restore
  gap=$(for n in 1 2 3; do tip $n | cut -d' ' -f1; done | grep -v NA | sort -n | awk 'NR == 1 { lo = $1 } { hi = $1 } END { print hi - lo }')
  restore
  h0=$(date +%s); healed=no
  while [ $(( $(date +%s) - h0 )) -lt "$HEAL_TIMEOUT" ]; do
    sample "$sc" heal
    if same_tip && sleep 10 && same_tip; then healed=yes; break; fi
    sleep 5
  done
  heal=$(( $(date +%s) - h0 ))
  echo "$sc,$secs,$during,$before,$gap,$heal,$healed" | tee -a "$OUT/summary.csv"
  [ "$healed" = yes ] || { echo "the pools did not agree again after $HEAL_TIMEOUT s: stopping here"; break; }
  sleep 120
done
echo "done: $OUT"
