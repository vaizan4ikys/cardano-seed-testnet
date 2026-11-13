# Phase 3 results: what does the gateway-list contract cost?

Measured on 13 November 2026 on the private chain net-1 (3 pools, protocol version 9, about 5 s per block), following
`PHASE3-PLAN.md` (version 2, reviewed by an independent agent before the run). Data: `phase3/results/steps.csv` (36 load steps +
1 discarded warm-up) and `phase3/results/costs.csv`. Summary tables: `python3 phase3/p3-summarize.py phase3/results/steps.csv phase3/results/costs.csv`.

Three variants send the same batch (100 readings, 1.3 KB of metadata):
* **P** plain metadata transaction (no contract)
* **S** contract transaction, script inside the transaction (what the gateway does today)
* **R** contract transaction, script stored once as a reference script, the transaction points to it

## Part A: one transaction

| variant | registry keys | size (bytes) | fee (lovelace) | script steps | script memory |
|---|---|---|---|---|---|
| P | - | 1,264 | 2,263 | - | - |
| S | 3 | 2,289 | 10,536 | 25.9 M | 81.8 k |
| S | 10 | 2,289 | 13,835 | 36.9 M | 120.0 k |
| S | 50 | 2,289 | 32,682 | 99.8 M | 338.3 k |
| R | 3 | 1,633 | 11,433 | 31.0 M | 99.8 k |
| R | 10 | 1,633 | 14,731 | 42.0 M | 138.1 k |
| R | 50 | 1,633 | 33,578 | 105.0 M | 356.4 k |

(Fees include a margin of 1,000 lovelace. Script steps and memory were measured by the node, not estimated.)

* The contract adds 1,025 bytes (+81 %) to a transaction when the script is inside it, and 369 bytes (+29 %) with a reference script.
* The size of the registry list does not change the transaction size, but the script has to search the list: execution units grow about
  linearly with the number of keys (about 1.6 M steps per key). Fee: 4.7 times the plain fee with 3 keys, 14 times with 50 keys.
* The reference-script variant is smaller in bytes, but here it needs MORE execution units than S (+5 M steps). The reason was not investigated.
* The execution units (62 M memory, 20 G steps per block) are not the limit: even at 50 keys a block would hold more than 150 such
  transactions by units. The byte limit of a block (65,536 bytes) is reached first.

## Part B: load test (6 repetitions per variant and rate, rotating order)

Offered 3.9 and 6.7 transactions per second (about 390 and 670 readings per second), 60 s per step, 50-key registry for S and R.
The rates come from the capacity of S: 65,536 bytes per block / 2,288 bytes = 28 transactions per block, about 5.6 transactions per second.

| offered | variant | readings/s delivered (median) | latency p50 | latency p90 |
|---|---|---|---|---|
| 3.9 tx/s | P | 383 | 4.2 s | 14.2 s |
| 3.9 tx/s | S | 347 | 5.6 s | 12.9 s |
| 3.9 tx/s | R | 373 | 3.6 s | 9.1 s |
| 6.7 tx/s | P | 630 | 3.5 s | 9.8 s |
| 6.7 tx/s | S | 489 | 11.8 s | 23.0 s |
| 6.7 tx/s | R | 536 | 6.9 s | 13.9 s |

What can be said:
* **Nothing was lost** in any step. No transaction was refused except 12 refusals in one P step at 6.7 tx/s (mempool full, the generator retried).
* **At 3.9 tx/s (below capacity) the three variants are not distinguishable**: every difference is inside the spread of the 6 P repetitions.
* **At 6.7 tx/s S is saturated.** In all 6 repetitions the blocks that carried S transactions held 28 transactions, 64,064 bytes (the limit
  is 65,536). Median latency 11.8 s against 3.5 s for P; this is the only difference that passed the plan's rule (larger than the
  spread of P and the same sign in at least 5 of 6 repetitions).
* **R fits more per block than S** (39 transactions, about 63.6 kB, against 28): by the arithmetic 65,536 / 1,632 = 40. Its latency at
  6.7 tx/s is between P and S, but the difference to P is not larger than the noise.
* P is far from its own limit (65,536 / 1,264 = 51 per block, about 10 tx/s).

## What this does not show
* The network is a test network: fee 1 lovelace per byte, no fixed fee, no fee for reference scripts (mainnet: 44 per byte plus a fixed part,
  15 per byte of reference script), 5 s blocks. Only comparisons between the variants are meaningful, not absolute rates or fees.
  On mainnet the reference-script variant would pay for the script bytes too, so it would not look cheaper in fees.
* The 3 pools, the generator and the node share 2 CPUs on one VM; one chain, one day. Submissions go to one pool only.
* Transactions per block and latency in blocks come from a sampler that polls the chain; block attribution can be off by 1 to 2 blocks.
  Per-block maxima are therefore not used. The medians at saturation are stable (S: 28 in all 6 repetitions).
* The spread between repetitions is large (P at 3.9 tx/s: 248 to 388 readings per second delivered), because block times are random
  (mean 5 s, so 60 s is only about 12 blocks). More repetitions or longer steps would be needed to resolve small differences.
* The CPU cost of the script was not measured (milliseconds, invisible on 2 shared CPUs); only execution units are reported.

## Conclusion for the design
The contract is affordable: a batch of 100 readings needs 2,289 bytes instead of 1,264, and a gateway list of 50 keys costs about 14 times
the plain fee on this chain. The real limit is block size: with the script inside every transaction a block holds 28 batches instead of
about 51. If the contract gateway should send more than about 5 batches per second in total, batches should be bigger (up to the 16,384-byte
transaction limit, so the script overhead is shared by more readings) or the script should be a reference script.
The registry list should stay short, because every key costs script steps in every transaction.

## State after the run
Registry list is exactly [A]; measurement keys deleted; Kupo running again; `demo.sh --yes` passed all 7 steps.
