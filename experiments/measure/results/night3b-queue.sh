#!/bin/bash
# Rest of the night: wait for the clock skew test (already running), then many nodes on one pool.
cd "$(dirname "$0")/.."
R=$PWD/results
until ! pgrep -f "[s]kew.sh" > /dev/null; do sleep 20; done
echo "$(date) skew done"
OUT=$R/fanout-main COUNTS="1 4 8 12" WINDOW=300 ./fanout.sh > $R/fanout-main.log 2>&1
echo "$(date) fanout done"
echo finished > $R/night3b-queue.done
