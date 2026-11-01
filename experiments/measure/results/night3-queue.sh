#!/bin/bash
# Night queue 3: wait for the failure tests on seedvm, then clock skew, many nodes on one pool, and last the
# "cut longer than k" test (which splits the chain for good); then start a fresh healthy chain with the load.
cd "$(dirname "$0")/.."
R=$PWD/results
echo "$(date) waiting for failures-main"
until ssh seedvm 'grep -q "^done:" ~/failures-main.log' 2>/dev/null; do sleep 30; done
echo "$(date) failures done"
OUT=$R/skew-main ./skew.sh > $R/skew-main.log 2>&1
echo "$(date) skew done"
OUT=$R/fanout-main COUNTS="1 4 8 12" WINDOW=300 ./fanout.sh > $R/fanout-main.log 2>&1
echo "$(date) fanout done"
ssh -A seedvm 'cd ~/cardano-seed-testnet && OUT=$HOME/failures-split SCENARIOS="cut3:1200" HEAL_TIMEOUT=600 ./experiments/measure/failures.sh > ~/failures-split.log 2>&1'
echo "$(date) split test done; starting a fresh chain"
ssh -A seedvm 'cd ~/cardano-seed-testnet && ./experiments/load/load.sh stop; PYTHONPATH=/home/seed/seed-emulator SKIP_NTP_CHECK=1 EXPOSE=1 ./run.sh > ~/run-net1-fresh.log 2>&1'
for i in $(seq 60); do b=$(ssh seedvm 'cd ~/cardano-seed-testnet && source scripts/lib.sh && tip_of 1' 2>/dev/null | grep -o '"block":[0-9]*' | grep -o '[0-9]*$'); [ -n "$b" ] && [ "$b" -ge 5 ] && break; sleep 15; done
ssh seedvm 'cd ~/cardano-seed-testnet && ./experiments/load/load.sh start'
echo "$(date) fresh chain at block $b, load started"
echo finished > $R/night3-queue.done
