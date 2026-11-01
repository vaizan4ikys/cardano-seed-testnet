# gateways

Many gateways, each with its own node and its own funded wallet, submit transactions at the same time from
different machines. This is the case of a sensor system: the capacity and the waiting time as the sites see them.
(`../saturation` submits from one place, inside pool 1's container.)

```
./gateways.sh                                           6 gateways, 100/200/300/400 readings per second in total
GATEWAYS=3 TOTALS="100 200" DURATION=60 ./gateways.sh   a short test
```

**Not tested yet** (written on 1 November 2026, to be run on a fresh network with the load off).

## What it does

1. Starts `GATEWAYS` nodes (`gw1` .. `gwN`, spread over seedvm2, seedvm3 and seedvm4); each dials pool 1.
2. Makes a key pair for every gateway inside its own container (the key never leaves it) and collects the addresses.
3. Pays every gateway `FUND` lovelace in one transaction from the funded genesis key `utxo1` (`in-container/gw-fund.sh`).
4. For every total rate in `TOTALS`: each gateway builds its own chain of signed transactions of `B` readings
   (`../saturation/in-container/sat-step.sh` with `KEY` and `START_AT`), and all gateways start submitting at the
   same second through their own node. A transaction is timed from its planned send time to the block that holds
   it, read from the gateway's own node.
5. `aggregate.py` adds up the gateways.

## Output

`results/gateways-<date-time>/steps.csv`: per total rate the readings offered and stored per second, the lowest and
highest share one gateway got, lost transactions, waiting time (median, p90, p99, max) and the largest waiting room.
Per gateway: `steps-R<total>-gw<k>.csv` and `txs-R<total>-gw<k>.csv`.

## Limits

Building and signing happen at the gateway (one `cardano-cli` process per transaction, about 0.5 s of CPU), before
the start, so their time is not in the waiting time. The link from a sensor to its gateway is not emulated.
Every gateway uses a single chain of transactions (one UTxO); real gateways that send in parallel need several.
