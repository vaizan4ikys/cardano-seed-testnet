#!/bin/bash
# After the many-nodes test: repeat the clock skew test with a proper clock restore between the offsets.
cd "$(dirname "$0")/.."
R=$PWD/results
until [ -f $R/night3b-queue.done ]; do sleep 30; done
OUT=$R/skew-main2 OFFSETS="-1 -2 -3 -5 -10 5" ./skew.sh > $R/skew-main2.log 2>&1
echo "$(date) skew2 done"
echo finished > $R/night3c-queue.done
