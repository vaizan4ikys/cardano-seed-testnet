#!/bin/bash
# Finality: how long until a transaction cannot be rolled back any more (K blocks deep)? Runs on your own
# machine (the Mac); the measuring script in-container/finality.sh runs inside pool 1's container on the
# pool VM (over ssh).
#
# Usage:
#   ./finality.sh                 12 transactions, K = 60 (the chain's security parameter)
#   N=6 K=60 ./finality.sh
#
# Environment (default):
#   POOL  the VM that runs the pools                 (POOL_HOST from scripts/config.sh)
#   N     number of transactions                     (12)
#   K     depth in blocks that counts as final       (60)
#   OUT   result folder                              (results/finality-<date-time> next to this script)
#
# About 5 minutes after the last transaction on the 5-second testnet (60 blocks at ~12 per minute).
# Output: results/finality-<date-time>/finality.csv (tx,inclusion_s,final_s,after_inclusion_s)
#         and summary.txt (the average line that is also printed at the end)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../../scripts/config.sh"            # POOL_HOST, REPO

POOL=${POOL:-$POOL_HOST}; N=${N:-12}; K=${K:-60}
OUT=${OUT:-$HERE/results/finality-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"

# Run in-container/finality.sh inside pool 1's container ($MAGIC comes from scripts/lib.sh on the VM)
# and keep its CSV on the screen and in the result folder.
ssh -A -o BatchMode=yes "$POOL" \
  "cd $REPO && source scripts/lib.sh && P=\$(require_pool 1) && docker exec -i -e MAGIC=\$MAGIC -e N=$N -e K=$K \$P bash -s" \
  < "$HERE/in-container/finality.sh" 2> >(grep -v '^\*\*' >&2) | tee "$OUT/finality.csv"

# the averages over all transactions
awk -F, 'NR > 1 { s += $2; f += $3; a += $4; n++ }
         END { if (n) printf "# %d transactions: in a block after %.1f s, final after %.1f s on average (%.1f s after inclusion)\n",
                      n, s / n, f / n, a / n }' "$OUT/finality.csv" | tee "$OUT/summary.txt"
