#!/bin/bash
# Mainnet-like parameters (f=0.05, k=2160, 90 KB blocks): fresh chain, then
# small matrix (join, tx latency, propagation), saturation, fork rate against pool delay.
cd "$(dirname "$0")/.."
R=$PWD/results; S=$PWD/../saturation
echo "$(date) start new chain"
ssh seedvm 'cd ~/cardano-seed-testnet && PARAMS=mainnet SKIP_NTP_CHECK=1 EXPOSE=1 PYTHONPATH=/home/seed/seed-emulator ./run.sh' > $R/mainnet-20261030-0915-run.log 2>&1 || { echo "run.sh failed"; exit 1; }
for i in $(seq 60); do
  b=$(ssh seedvm 'cd ~/cardano-seed-testnet && source scripts/lib.sh && tip_of 1' 2>/dev/null | grep -o '"block":[0-9]*' | grep -o '[0-9]*$')
  [ -n "$b" ] && [ "$b" -ge 3 ] && break; sleep 20
done
echo "$(date) chain at block $b"
ssh seedvm 'cd ~/cardano-seed-testnet && FILL_TXS=8 ./experiments/load/load.sh start'
sleep 420
ssh seedvm 'cd ~/cardano-seed-testnet && ./experiments/load/load.sh stop'
echo "$(date) matrix"
OUT=$R/mainnet-20261030-0915-matrix DELAYS="0 200 500" LOSSES="0" REPS=2 TXS=6 IDLE=240 ./run-all.sh > $R/mainnet-20261030-0915-matrix.log 2>&1
echo "$(date) saturation"
(cd $S && OUT=$S/results/mainnet-20261030-0915 STEPS="100:0.5 100:1 100:1.5 100:2 300:0.2 300:0.4 300:0.6 300:0.8" DURATION=120 ./saturate.sh > $R/mainnet-20261030-0915-saturation.log 2>&1)
echo "$(date) forks"
ssh seedvm 'cd ~/cardano-seed-testnet && FILL_TXS=8 ./experiments/load/load.sh start'
sleep 240
OUT=$R/mainnet-20261030-0915-forks DELAYS="0 500 1000 2000" MINUTES=30 ./forks.sh > $R/mainnet-20261030-0915-forks.log 2>&1
ssh seedvm 'cd ~/cardano-seed-testnet && ./experiments/load/load.sh stop'
echo "$(date) finished"
echo finished > $R/mainnet-20261030-0915.done
