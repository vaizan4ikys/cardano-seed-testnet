#!/bin/bash
# night queue 2: load on, big-chain matrix, then the asymmetric-delay test
cd "/Users/pavloharabadzhiiev/cardano-seed-testnet/experiments/measure"
ssh seedvm 'cd ~/cardano-seed-testnet && ./experiments/load/load.sh start' 2>&1 | grep -v -e '^\*\*'
sleep 90
OUT=/Users/pavloharabadzhiiev/cardano-seed-testnet/experiments/measure/results/matrix-big-20261030-0407 DELAYS="0 100 200" LOSSES="0 1" REPS=2 TXS=6 IDLE=60 ./run-all.sh > /Users/pavloharabadzhiiev/cardano-seed-testnet/experiments/measure/results/matrix-big-20261030-0407.log 2>&1
OUT=/Users/pavloharabadzhiiev/cardano-seed-testnet/experiments/measure/results/asymmetric-20261030-0407 ./asymmetric.sh > /Users/pavloharabadzhiiev/cardano-seed-testnet/experiments/measure/results/asymmetric-20261030-0407.log 2>&1
echo finished > /Users/pavloharabadzhiiev/cardano-seed-testnet/experiments/measure/results/night2-queue.done
