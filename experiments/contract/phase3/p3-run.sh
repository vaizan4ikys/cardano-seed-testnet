#!/bin/bash
# Runs INSIDE pool 1's container (start it with docker exec -d: it survives ssh drops). Phase 3 part B, see ../PHASE3-PLAN.md.
#   LOW=3.9 HIGH=6.7 REPS=6 DURATION=60 ./p3-run.sh <magic>
# One discarded warm-up step (P, low rate), then REPS repetitions; in each repetition, for both rates (the rate order alternates)
# the three variants in a rotating order (reps 0-2 cyclic, reps 3-5 reversed cyclic). Results: /tmp/p3/results/steps.csv,
# txs/<id>.csv, progress.log. Resumable: steps already in steps.csv are skipped. Stop early: touch /tmp/p3/results/STOP
# (the Mac-side watcher does that when the Mac has < 6 GB free disk or is off AC power).
set -u
MAGIC=${1:?usage: p3-run.sh <magic>}; export MAGIC
LOW=${LOW:?}; HIGH=${HIGH:?}; REPS=${REPS:-6}; DURATION=${DURATION:-60}; REST=${REST:-15}
. /tmp/p3-scripts/p3-lib.sh
R=$W/results; mkdir -p $R/txs; cd $W
log() { echo "$(date -u +%T) $*" | tee -a $R/progress.log; }
tipblk() { cli query tip --testnet-magic "$MAGIC" 2>/dev/null | jq -r .block; }
drain() {
  local n=1 i
  for i in $(seq 120); do
    n=$(cli query tx-mempool info --testnet-magic "$MAGIC" 2>/dev/null | jq -r .numberOfTxs)
    [ "$n" = 0 ] && return 0; sleep 5
  done
  log "mempool still has $n transactions after 10 minutes"; return 1
}
ORDERS=("P S R" "S R P" "R P S" "R S P" "S P R" "P R S")
PLAN=("warmup 0 P $LOW")
for r in $(seq 0 $((REPS - 1))); do
  if [ $((r % 2)) = 0 ]; then RATES="$LOW $HIGH"; else RATES="$HIGH $LOW"; fi
  for rate in $RATES; do for v in ${ORDERS[$((r % 6))]}; do PLAN+=("r$r-$rate-$v $r $v $rate"); done; done
done
log "plan: ${#PLAN[@]} steps, low $LOW high $HIGH tx/s, $DURATION s each; registry keys $(registry_list | jq length)"
for entry in "${PLAN[@]}"; do
  set -- $entry; id=$1; rep=$2; v=$3; rate=$4
  [ -f $R/STOP ] && { log "STOP file found: ending"; exit 0; }
  if [ -f $R/steps.csv ] && grep -q "^$id," $R/steps.csv; then continue; fi
  avail=$(free -m | awk '/^Mem/ {print $7}'); [ "$avail" -ge 400 ] || { log "only $avail MiB free: stopping"; exit 1; }
  dfree=$(df -BG --output=avail /tmp | tail -1 | tr -dc 0-9); [ "${dfree:-0}" -ge 6 ] || { log "only $dfree GB free disk: stopping"; exit 1; }
  drain || exit 1
  before=$(tipblk)
  log "step $id: variant $v, $rate tx/s, $DURATION s (tip $before, mem avail $avail MiB)"
  OUT=$(bash /tmp/p3-scripts/p3-step.sh "$MAGIC" "$v" "$rate" "$DURATION" 2>&1) || { log "step $id FAILED: $(echo "$OUT" | tail -3 | tr '\n' ' ' | cut -c1-300)"; exit 1; }
  after=$(tipblk)
  [ "${after:-0}" -gt "${before:-0}" ] || { log "the chain did not advance during $id ($before -> $after): stopping"; exit 1; }
  S=$W/step
  [ -f $R/steps.csv ] || echo "id,rep,variant,rate_tx_s,$(head -1 $S/summary.csv),$(head -1 $S/extra.csv),invalid_reason" > $R/steps.csv
  reason=""
  conf=$(tail -1 $S/summary.csv | cut -d, -f12); plan_n=$(tail -1 $S/summary.csv | cut -d, -f6)
  [ "$(awk -v c="$conf" -v p="$plan_n" 'BEGIN { print (c < 0.9 * p) }')" = 1 ] && reason="confirmed $conf of $plan_n"
  [ -s $S/rejects.log ] && grep -v -i -E "mempool|capacity|full" $S/rejects.log | grep -q . && reason="$reason; refusal other than a full mempool"
  echo "$id,$rep,$v,$rate,$(tail -1 $S/summary.csv),$(tail -1 $S/extra.csv),$reason" >> $R/steps.csv
  cp $S/txs.csv $R/txs/$id.csv; [ -s $S/rejects.log ] && cp $S/rejects.log $R/txs/$id.rejects.log
  log "step $id done: $(tail -1 $S/summary.csv | cut -d, -f7,10,11,12,13,14,16,17 ) | blocks: $(tail -1 $S/extra.csv)${reason:+ | NOTE: $reason}"
  drain || exit 1
  sleep $REST
done
log "ALL STEPS DONE"
