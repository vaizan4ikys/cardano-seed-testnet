#!/bin/bash
# Repeat the join-time-per-hop series three times (an outlier made the chart look odd), then the clock skew test three times.
cd "$(dirname "$0")/.."
R=$PWD/results
OUT=$R/hopjoin-rep JOIN_ONLY=1 REPS=3 HOPS=6 DELAYS="0 50 100" ./hops.sh > $R/hopjoin-rep.log 2>&1
echo "$(date) hopjoin done"
OUT=$R/skew-rep REPS=3 OFFSETS="-1 -2 -3 -5 -10 5" ./skew.sh > $R/skew-rep.log 2>&1
echo "$(date) skew reps done"
echo finished > $R/night4-queue.done
