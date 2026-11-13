#!/bin/bash
# Runs in the step folder after sat-analyze.sh (summary.csv, txs.csv exist). Adds the numbers in BLOCKS (extra.csv):
#   blocks_window       blocks that came during the submitting (tip at T0+D minus tip at T0)
#   txs_block_med/max   transactions confirmed per block, over the blocks of the window that confirmed at least one
#   bytes_block_med     the median times the transaction size
#   lat_blk_p50/p90     blocks between the block that was the tip at the planned time and the block that confirmed it
#   needs T0 D SIZE; samples.txt (t lane idx block), submits.txt (lane k sched submitted), blocks.txt (t block)
set -u
awk -v T0="$T0" -v D="$D" -v SIZE="$SIZE" '
  FILENAME == "blocks.txt" { nb++; bt[nb] = $1; bb[nb] = $2; next }
  FILENAME == "samples.txt" { l = $2; k = $3; if (!(l in last)) last[l] = -1
      for (j = last[l] + 1; j <= k; j++) { cblk[l, j] = $4; ct[l, j] = $1 }
      if (k > last[l]) last[l] = k; next }
  FILENAME == "submits.txt" { sched[$1, $2] = $3; next }
  END {
    # tip block at a time: the last blocks.txt sample not later than the time
    for (key in sched) {
      if (!(key in cblk)) continue
      t = sched[key]; b0 = bb[1]; for (j = 1; j <= nb; j++) { if (bt[j] <= t) b0 = bb[j]; else break }
      d = cblk[key] - b0; if (d < 0) d = 0
      lat[++nl] = d; cnt[cblk[key]]++
    }
    bw0 = bb[1]; bw1 = bb[nb]
    for (j = 1; j <= nb; j++) { if (bt[j] <= T0) bw0 = bb[j]; if (bt[j] <= T0 + D) bw1 = bb[j] }
    n = 0; mx = 0
    for (b in cnt) if (b + 0 > bw0 && b + 0 <= bw1) { v[++n] = cnt[b]; if (cnt[b] > mx) mx = cnt[b] }
    # sort v and lat (small arrays)
    for (a = 2; a <= n; a++) { x = v[a]; j = a - 1; while (j > 0 && v[j] > x) { v[j + 1] = v[j]; j-- } v[j + 1] = x }
    for (a = 2; a <= nl; a++) { x = lat[a]; j = a - 1; while (j > 0 && lat[j] > x) { lat[j + 1] = lat[j]; j-- } lat[j + 1] = x }
    med = (n ? ((n % 2) ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2) : 0)
    i50 = int(0.5 * nl + 0.9999); i90 = int(0.9 * nl + 0.9999); if (i50 < 1) i50 = 1; if (i90 < 1) i90 = 1
    print "blocks_window,txs_block_med,txs_block_max,bytes_block_med,lat_blk_p50,lat_blk_p90" > "extra.csv"
    printf "%d,%.1f,%d,%.0f,%s,%s\n", bw1 - bw0, med, mx, med * SIZE, (nl ? lat[i50] : "NA"), (nl ? lat[i90] : "NA") >> "extra.csv"
  }' blocks.txt samples.txt submits.txt
cat extra.csv
