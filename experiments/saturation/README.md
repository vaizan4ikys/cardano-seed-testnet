# saturation: how many sensor readings per second can the chain take?

A sensor gateway sends small metadata transactions. This experiment sends them at a fixed rate and
measures how many end up in blocks per second and how long each one waits, for several batch sizes
(readings per transaction) and rates. The point where delivered readings stop following the offered
ones, and the waiting time grows, is the capacity of the chain for that kind of load.

```bash
./experiments/load/load.sh stop           # the load fills the blocks: it must be off
./experiments/saturation/saturate.sh      # the series, about 1.5 hours; writes to the chain (about 1 MB per step)
python3 experiments/saturation/summarize.py experiments/saturation/results/saturation-<date-time>
STEPS="100:1 100:3" DURATION=60 ./experiments/saturation/saturate.sh    # short test: <readings per tx>:<tx per second>
```

Run it on your own machine; it needs network 1 running on the pool machine (as `seedvm`, see
`../measure`).

## How a step works

* A reading is a 40-character string (42 bytes in the transaction metadata, label 1000). A transaction
  carries `B` of them: 1, 10, 100 or 300 (limit: the transaction size, 16384 bytes). Sizes: 285 bytes
  for 1 reading, 12,845 bytes for 300.
* The transactions are built and signed **before** the step (`cardano-cli` needs a process per
  transaction), in `LANES` independent chains: each transaction spends the output of the previous one
  in its lane, so nothing waits for a block before the next is sent.
* One worker per lane submits its transactions at the planned times from pool 1's container, using
  utxo2 (the key of `../load`). If the node refuses one (mempool full) the worker tries again every
  second and counts a rejection, as a gateway would; after 60 s it gives up and the rest of its lane is lost.
* Once per second the UTxOs of the address are read. The UTxO of a lane is the output of its newest
  transaction that is in a block, so its position in the lane says how many are confirmed. A
  transaction's **latency** runs from its *planned* time (not the actual submit time, so a waiting
  gateway counts) to the first reading that shows it in a block. Resolution about 0.5 s; blocks come
  about every 5 s, so the numbers are mostly the wait for a block.
* After the last submit it waits up to 300 s for the rest. The next step starts when the mempool is empty.

## Result columns (`steps.csv`)

| Column | Meaning |
|---|---|
| `batch`, `tx_bytes`, `rate_target_tx_s` | readings per transaction, transaction size, planned rate |
| `offered_tx_s`, `offered_readings_s` | what was actually submitted per second (lower than the target if the generator could not keep up) |
| `delivered_readings_s` | readings that were in a block before the submitting ended, per second |
| `backlog_end` | transactions submitted but not yet in a block when the submitting ended |
| `lost`, `rejections` | transactions never confirmed; refused submits (retried) |
| `lat_p50`, `lat_p90`, `lat_p99`, `lat_max` | seconds from planned submit to block |
| `mempool_max_bytes` | the largest mempool seen (capacity 129,024 bytes) |

`txs-B<b>-r<rate>.csv` has one row per transaction: lane, number, planned, submitted and confirmed time
(seconds after the start of the step).

## Limits

* **The generator limits the rate.** `cardano-cli` starts a process for every submit, so on a 2-CPU
  machine that also runs the pools about 20 transactions per second is the most it can do (the
  `offered_tx_s` column shows what it did). The chain can take about 1 transaction per second of
  300 readings, 3 of 100, 19 of 10 and 47 of 1 (a 64 KB block, about 12 blocks per minute). So the
  capacity is reached with 100 and 300 readings per transaction; with 1 and 10 the numbers show the limit
  of the generator, which is a result about the client tool, not about the chain.
* "Delivered" counts only what was in a block before the submitting ended, so it is a little low for
  short steps (the last 5 s of transactions are still waiting).
* The chain's own timings (about 5 s per block) are those of the test network (active slot coefficient 0.2,
  1-second slots), not those of mainnet.
