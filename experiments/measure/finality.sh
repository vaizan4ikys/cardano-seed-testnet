#!/bin/bash
# Finality: how long until a transaction cannot be rolled back any more (K blocks deep)? Run from your own machine.
#
#   ./finality.sh                 12 transactions, K = 60 (the chain's security parameter)
#   N=6 K=60 ./finality.sh
#
# About 5 minutes after the last transaction on the 5-second testnet (60 blocks at ~12 per minute).
# Output: results/finality-<date-time>/finality.csv (tx,inclusion_s,final_s,after_inclusion_s)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
POOL=${POOL:-seedvm}; N=${N:-12}; K=${K:-60}
OUT=${OUT:-$HERE/results/finality-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
ssh -A -o BatchMode=yes "$POOL" "cd cardano-seed-testnet && source scripts/lib.sh && P=\$(require_pool 1) && docker exec -i -e MAGIC=\$MAGIC -e N=$N -e K=$K \$P bash -s" \
  < "$HERE/in-container/finality.sh" 2> >(grep -v '^\*\*' >&2) | tee "$OUT/finality.csv"
awk -F, 'NR > 1 { s += $2; f += $3; a += $4; n++ } END { if (n) printf "# %d transactions: in a block after %.1f s, final after %.1f s on average (%.1f s after inclusion)\n", n, s / n, f / n, a / n }' "$OUT/finality.csv" | tee "$OUT/summary.txt"
