# measure: how fast does a node join, and how long does a transaction take?

Measurements on a running network 1 with joiner nodes on other machines (see `../join-node`).
Four machines: the **pool** machine (SEED, 3 pools), **hop 1** (a joiner that dials a pool and
serves the next one), **hop 1b** (a second joiner on a pool) and **hop 2** (a joiner that dials
hop 1, so two hops from the pools):

```
pool machine  <--  hop 1 (seedvm2)  <--  hop 2 (seedvm4)
      ^
      +---------  hop 1b (seedvm3)
```

| Measurement | Script | Result |
|---|---|---|
| Sync from an empty database | `sync-time.sh` | seconds until the joiner is caught up, split into node start-up and sync |
| Three joiners syncing at once | `run-all.sh` | the same, with the pools serving all three |
| Transaction latency | `tx-latency.sh` | seconds from submit on a remote node until the pool's mempool has it, and until the block on that node |
| Block propagation per hop | `propagation.py` | ms from the forging pool to each node (median, p95, max) |
| Pool block rate | `propagation.py` | blocks per minute of the chain |
| Slow or lossy link | `netem.sh` | delay and loss on a joiner's link, used by all of the above |
| Clocks | `setup-clocks.sh`, `clock-offsets.py` | chrony on all machines; offsets between them |

## Before the first run: synchronise the clocks

Block propagation compares log timestamps of different machines, so their clocks must agree to
about a millisecond. Left alone they differ by tens of milliseconds, and VMware adjusts the guest
clocks by itself. Run this once on your own machine (it installs `chrony`, needs internet and
`sudo` on the machines):

```bash
./experiments/measure/setup-clocks.sh        # seedvm is the time server, the others follow it
python3 experiments/measure/clock-offsets.py seedvm seedvm2 seedvm3 seedvm4   # check
```

The time server is the only clock source of the group (no internet time), on purpose: if your
machine sleeps, the virtual machines freeze, and a clock that follows the internet would then jump
forward by the length of the sleep, which kills the chain (more than 15 minutes without a block).
Keep the machine awake all the same (`caffeinate -dims`).

The offsets printed by the check are against your own machine; they should be equal to within
about 1 ms. (Without this step the propagation numbers carry an error of 30 ms or more, which is
as large as the delays in the fast settings.)

## One command

```bash
./experiments/measure/run-all.sh                                   # full matrix, ~1 hour
DELAYS="0 100" LOSSES="0" REPS=1 TXS=2 IDLE=20 ./experiments/measure/run-all.sh   # short test
```

Run it on your own machine. It needs network 1 running (`EXPOSE=1 ./run.sh` on the pool machine)
and this repo on every machine. For each delay (0, 50, 100, 200, 500 ms) and loss (0, 1 %) it
syncs hop 1 and hop 2 from an empty database `REPS` times, waits `IDLE` seconds, sends `TXS`
transactions from each, and reads the node logs. A first run per boot is thrown away
(the files are read from disk the first time).

Results go to `results/<date-time>/`:

| File | Columns |
|---|---|
| `setup.txt` | machines, their clock error against the time server, commit, chain at the start |
| `sync.csv` | `delay_ms,loss_pct,mode,rep,node,hops,seconds,ready_seconds,blocks,sync_seconds,db_kb` |
| `tx.csv` | `delay_ms,loss_pct,node,hops,seconds,mempool_seconds` |
| `propagation.csv` | `delay_ms,loss_pct,node,blocks,median_ms,p95_ms,max_ms` |
| `offsets.csv` | `delay_ms,loss_pct,machine,offset_ms,round_trip_ms` clock offsets used for the propagation |
| `blockrate.txt` | blocks per minute for each setting |
| `summary.txt` | the tables of `./summarize.py results/<date-time>`: medians and percentiles per setting |
| `logs/` | the node logs the propagation numbers come from |

## A growing chain: checkpoints

To see how the numbers change when the chain gets big, fill the blocks with `../load/load.sh` and let
`checkpoints.sh` repeat a short series every 30 minutes (leave the Mac awake):

```bash
./experiments/load/load.sh start                      # on the pool machine
caffeinate -dims ./experiments/measure/checkpoints.sh  # on your own machine, until stopped
./experiments/measure/growth.py results/growth-<date-time>   # one table: join time, copy rate, latency against chain size
```

Each checkpoint is `run-all.sh` with delay 0 and 100 ms (2 joins, 6 transactions per node) plus the
size of the chain (`chain.csv`). `touch results/growth-<date-time>/stop` ends it after the current
checkpoint.

## The single scripts

```bash
./sync-time.sh <peer-ip>                 # on a joiner machine, after fetch-chain-files.sh
DELAY=100 LOSS=1 ./sync-time.sh <peer-ip>
./tx-latency.sh seedvm2                  # on your machine
./netem.sh set 100 1 | clear | show      # on a joiner machine, while its joiner runs
```

## What the numbers mean

* **Sync time** (`seconds`) runs from `docker run` until the node's tip is at most 20 slots
  (20 s) older than the clock of the chain. `ready_seconds` is the part until the node answers at
  all (its start-up, about 0.5 s); `sync_seconds` is the difference. It grows with the chain
  height, so compare runs at a similar height (`blocks` says which).
  On a cloned machine the `127.0.1.1` line of `/etc/hosts` must carry the new hostname, otherwise
  every `sudo` waits 15 s and that time ends up in the measurement (see `docs/troubleshooting.md`).
* **Transaction latency** has two parts. `mempool_seconds` is how long the transaction needs to
  reach the pool; it shows the effect of the link, and compares the clocks of two machines, so
  it needs `setup-clocks.sh`. `seconds` adds the wait for a block and is mostly that wait: about
  5 s on average with a long tail (0.1 to 20 s), because blocks come at random (active slot
  coefficient 0.2) and a transaction can miss a block whose leader has not received it yet.
  So look at the median and the 90th percentile of many samples, not at single values. One
  transaction per node is sent first and dropped (the first one after a start is often slow).
  `seconds` is measured on one machine, so clock offsets do not matter.
* **Propagation** compares clocks of different machines. With `setup-clocks.sh` they agree to
  about 1 ms; `offsets.csv` holds the offsets measured for each setting and they are subtracted.
  The forger of a block is the node that logs it first; its own blocks are not counted
  for that node.
* **Delay and loss** act on what a joiner sends, so the round trip to its peer grows by the
  delay. They are applied right after the container starts (a few milliseconds), inside the
  container only; ssh to the machine is not affected.
* All machines share one physical CPU and disk. Compare settings with each other; do not read
  the absolute numbers as those of a real network.

## More scripts (second round of measurements)

| Script | What it measures |
|---|---|
| `forks.sh` | blocks lost to forks against the delay between the pools |
| `asymmetric.sh` | which link adds what: delay on one joiner at a time |
| `profiles.sh` | join time, block arrival and transaction time on realistic links (download and upload caps, delay, loss) |
| `hops.sh` | a chain of up to 6 nodes: block arrival, join time and transaction time per hop (`JOIN_ONLY=1 REPS=3` for the join times only) |
| `finality.sh` | seconds until a transaction is 60 blocks deep (cannot be rolled back) |
| `outage.sh`, `catchup.sh` | a node is cut off for 1, 5 and 15 minutes: time to catch up |
| `traffic.sh` | bytes a node sends and receives in normal operation (idle and full blocks) |
| `fanout.sh` | 1 to 12 nodes dialling one pool: block arrival, pool CPU and traffic |
| `skew.sh` | a node whose clock is wrong by 1 to 10 seconds |
| `failures.sh` | run on the pool machine: stop pools and cut a pool off the network, time until the pools agree again |
| `resources.sh` | CPU and memory of every machine once a minute during a run |

`netem.sh set <delay> [loss [down-Mbit [up-Mbit]]]` adds delay, loss and bandwidth limits to a node's container. `join.sh`, `netem.sh`, `sync-time.sh` and `tx-latency.sh` take `NAME=` (and `HOST_PORT=`) to address several nodes on one machine. `sync-time.sh` also prints the MB the node received.

In zsh write `"${vm}:path"`, not `$vm:path`: `:p` and `:c` after a variable are modifiers.

