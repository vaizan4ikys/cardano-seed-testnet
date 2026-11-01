#!/bin/bash
# Fork rate against the delay between the pools. Run from your own machine over SSH.
#
#   ./forks.sh                                  DELAYS="0 100 300 600", 20 minutes each
#   DELAYS="0 200" MINUTES=5 ./forks.sh         a short test
#
# For each delay every pool gets that delay on what it sends (tc netem in the pool container),
# so a block needs about that long to get from one pool to the next. Then the pool logs are
# counted: blocks added to the chain, forks switched to (a block that lost against another one
# for the same height), blocks the pools forged but did not adopt. It also takes the chain tip
# at the start and at the end (blocks per minute that survive).
#
# Whatever load is running keeps running; the numbers are comparable between delays only if the
# load is the same in all of them (start it before, or stop it before).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
POOL=${POOL:-seedvm}
DELAYS=${DELAYS:-"0 100 300 600"}
MINUTES=${MINUTES:-20}
OUT=${OUT:-$HERE/results/forks-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"

on() { ssh -A -o BatchMode=yes "$POOL" "cd cardano-seed-testnet && $*" 2> >(grep -v '^\*\*' >&2); }
# delay (and nothing else) on the three pool containers; "clear" removes it
netem() {
  on 'source scripts/lib.sh && for p in 1 2 3; do
        pid=$(docker inspect -f "{{.State.Pid}}" $(pool_container $p))
        if [ "'"$1"'" = clear ]; then sudo nsenter -t $pid -n tc qdisc del dev net0 root 2>/dev/null || true
        else sudo nsenter -t $pid -n tc qdisc replace dev net0 root netem delay '"${2:-0}"'ms; fi
      done'
}
trap 'netem clear' EXIT
tip() { on 'source scripts/lib.sh && tip_of 1' | grep -o '"block": *[0-9]*' | grep -o '[0-9]*$'; }
count() { on 'source scripts/lib.sh && docker exec $(pool_container '"$1"') grep -c "'"$2"'" /var/log/cardano-node.log' || true; }

echo "delay_ms,minutes,blocks,blocks_per_min,pool,extended,forks,forged,not_adopted" > "$OUT/forks.csv"
echo "# $(date -u +%FT%TZ): ${MINUTES} min per delay; pools in one SEED network, delay on each pool's egress" > "$OUT/setup.txt"

for delay in $DELAYS; do
  echo "== delay $delay ms"
  netem set "$delay"
  sleep 60                                  # let the chain settle at the new delay
  B0=$(tip); T0=$(date +%s)
  for p in 1 2 3; do
    E0[$p]=$(count $p "Chain extended"); F0[$p]=$(count $p "AddBlockEvent.SwitchedToAFork")
    G0[$p]=$(count $p "Forge.Loop.ForgedBlock"); N0[$p]=$(count $p "Forge.Loop.DidntAdoptBlock")
  done
  sleep $((MINUTES * 60))
  B1=$(tip); T1=$(date +%s)
  for p in 1 2 3; do
    e=$(count $p "Chain extended"); f=$(count $p "AddBlockEvent.SwitchedToAFork")
    g=$(count $p "Forge.Loop.ForgedBlock"); n=$(count $p "Forge.Loop.DidntAdoptBlock")
    awk -v d="$delay" -v s=$((T1 - T0)) -v b=$((B1 - B0)) -v p="pool$p" -v e=$((e - E0[$p])) -v f=$((f - F0[$p])) -v g=$((g - G0[$p])) -v n=$((n - N0[$p])) \
      'BEGIN { printf "%s,%.1f,%d,%.2f,%s,%d,%d,%d,%d\n", d, s / 60, b, b * 60 / s, p, e, f, g, n }' >> "$OUT/forks.csv"
  done
done
netem clear
trap - EXIT
echo "done: $OUT/forks.csv"
