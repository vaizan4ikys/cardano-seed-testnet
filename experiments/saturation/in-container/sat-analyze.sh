#!/bin/bash
# Runs INSIDE a node container, in the step folder. Turns the files of one step (samples.txt,
# submits.txt, rejects.log, mempool.txt in the current folder) into txs.csv and summary.csv.
# Called by sat-step.sh (and by experiments/contract/phase3/p3-step.sh); can be run on made-up
# files to test.
#
#   needs (environment): T0 D B RATE LANES SIZE PLANNED
#     T0 start time (epoch s), D seconds of submitting, B readings per tx, RATE tx/s in total,
#     LANES number of lanes, SIZE bytes per tx, PLANNED number of transactions planned
#   input files:  samples.txt  "<time> <lane> <k>"          a lane's newest confirmed tx, once per reading
#                 submits.txt  "<lane> <k> <planned> <submitted>"
#   output files: txs.csv      one row per transaction (lane,k,planned_s,submitted_s,confirmed_s)
#                 summary.csv  header + one row per step (printed at the end)
set -u

# --- txs.csv and partial.csv (the numbers that need all transactions) ---
# samples: every transaction of a lane up to index "idx" counts as confirmed at the sample time
# submits: when each transaction was planned and when it was really submitted
awk -v T0="$T0" -v D="$D" -v B="$B" -v RATE="$RATE" -v LANES="$LANES" -v SIZE="$SIZE" -v PLANNED="$PLANNED" \
    -v REJ="$(wc -l < rejects.log)" '
  FILENAME == "samples.txt" { t = $1; l = $2; idx = $3
      if (!(l in last)) last[l] = -1
      for (k = last[l] + 1; k <= idx; k++) conf[l, k] = t
      if (idx > last[l]) last[l] = idx
      if (t > lastsample) lastsample = t; next }
  FILENAME == "submits.txt" { sub_t[$1, $2] = $4; sched[$1, $2] = $3; nsub++
      if ($4 > lastsub) lastsub = $4
      if ($4 <= T0 + D) subwin++
      next }
  END {
    print "lane,k,planned_s,submitted_s,confirmed_s" > "txs.csv"
    for (key in sched) {
      split(key, p, SUBSEP)
      if (key in conf) {
        printf "%.3f\n", conf[key] - sched[key] > "lat.txt"
        printf "%s,%s,%.3f,%.3f,%.3f\n", p[1], p[2], sched[key] - T0, sub_t[key] - T0, conf[key] - T0 > "txs.csv"
        nconf++; if (conf[key] <= T0 + D) cwin++; if (conf[key] > lastconf) lastconf = conf[key]
      } else {
        printf "%s,%s,%.3f,%.3f,\n", p[1], p[2], sched[key] - T0, sub_t[key] - T0 > "txs.csv"
      }
    }
    span = (lastsub > T0) ? lastsub - T0 : D
    printf "%d,%s,%d,%d,%d,%d,%.2f,%.1f,%d,%.1f,%d,%d,%d,%d,%.0f\n",
        B, RATE, SIZE, LANES, D, PLANNED, nsub / span, nsub / span * B, cwin, cwin * B / D, subwin - cwin,
        nconf, PLANNED - nconf, REJ, (nconf ? lastconf - T0 : 0) > "partial.csv"
  }' samples.txt submits.txt

# --- percentile of lat.txt (waiting times, one per confirmed tx): pct 0.9 -> p90, "NA" if there are none ---
pct() {
  sort -n lat.txt | awk -v q="$1" '
    { a[NR] = $1 }
    END { if (NR) { i = int(q * NR + 0.9999); if (i < 1) i = 1; printf "%.2f", a[i] } else printf "NA" }'
}
touch lat.txt

# --- summary.csv: the partial row plus the percentiles and the largest mempool seen ---
MEMPOOL_MAX=$(awk 'NF >= 3 && $3 + 0 > m { m = $3 + 0 } END { print m + 0 }' mempool.txt)
{
  echo "batch,rate_target_tx_s,tx_bytes,lanes,duration_s,txs_planned,offered_tx_s,offered_readings_s,confirmed_in_window,delivered_readings_s,backlog_end,confirmed_total,lost,rejections,last_confirm_s,lat_p50,lat_p90,lat_p99,lat_max,mempool_max_bytes"
  echo "$(cat partial.csv),$(pct 0.5),$(pct 0.9),$(pct 0.99),$(pct 1),$MEMPOOL_MAX"
} > summary.csv
cat summary.csv
