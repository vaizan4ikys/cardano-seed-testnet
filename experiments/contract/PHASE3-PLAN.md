# Phase 3 plan (version 2): what does the gateway-list contract cost?

Version 1 was reviewed by an independent agent (13 Nov 2026); this version includes its corrections. Written before any measurement.
Chain: net-1 on seedvm (2 CPU, 3.9 GB RAM), 3 pools, protocol version 9, about 5 s per block (active slot coefficient 0.2),
block body limit 65,536 bytes, mempool 129,024 bytes, max tx size 16,384 bytes, max block execution units 62,000,000 memory /
20,000,000,000 steps, fee 1 lovelace per byte and no fixed part (mainnet: 44 per byte + 155,381), reference-script fee per byte 0
(mainnet: 15), coinsPerUTxOByte 4,310, max 3 collateral inputs.

## Question
A gateway sends a batch of 100 readings (about 1.3 KB of metadata) in one transaction. With the contract the transaction also mints
one RECEIPT token under the Plutus policy, references the registry coin, names collateral, and carries the script (about 0.7 KB)
and a redeemer. What does that cost in bytes, fee, waiting time and capacity compared with the same batch as a plain metadata
transaction? Does the size of the registry list matter? Does storing the script once as a reference script help?

## Variants
* **P**  plain metadata transaction, no script. (This is also the baseline re-run on protocol version 9.)
* **S**  contract transaction, script inside the transaction (what the gateway does today).
* **R**  contract transaction, script as a REFERENCE script (stored once in a coin, the transaction points to it).
Each variant has its own key and its own lane coins (equal ADA amount, so that number widths in the encoding are equal):
kP, kS, kR. kS and kR are on the registry list, at the END of the list (worst case for the list search). The registry list is
[A, 47 random dummy key hashes, kS, kR] = 50 keys for Part B (A stays enrolled: the demo needs it). Metadata of all variants:
the same real batch (100 readings, layout.py format) under label 9000 (not 1000), so the page and its reader never mistake the
test traffic for sensor data.

## Part A: cost of ONE transaction (about 20 minutes, chain idle)
For P and for S and R at registry sizes N = 3 (A, kS, kR), 10, 50: size in bytes, fee, execution units measured by the node
(`transaction build` evaluates the script; read with `transaction view`), and the difference to P. The execution units declared
in Part B for S and R are the measured values at N = 50 plus 10 %. The registry coin needs a top-up for large lists (minimum UTxO
about 1.7 KB x 4,310 lovelace): the registry change spends the registry coin plus one more administrator coin.

## Part B: load test (about 2 hours)
Design of `experiments/saturation`: transactions built and signed BEFORE the step, 8 lanes (chains), workers submit at planned
times from inside pool 1's container, a sampler reads the lane coins, drain between steps. New: the sampler also records the tip
block number each round, so results are also given in blocks (transactions per block, bytes per block, latency in blocks), because
block times are random (mean 5 s) and 60 s is only about 12 blocks.
Rates after Part A, from the size of S: capacity of S = floor(65,536 / size_S) transactions per block / 5 s. Low = 0.7 x that,
high = 1.2 x that (P is below its own capacity at both; it is stated in the result).
Steps: DURATION 60 s. One discarded warm-up step (P, low). Then 6 repetitions; in each repetition for each of the two rates
(order of the rates alternates between repetitions) the 3 variants run in a rotating order (two 3 x 3 Latin squares: the second one reversed). 36 steps.
Per step: transactions per second offered, readings per second delivered (confirmed before the submitting ended), backlog at the end,
rejections, lost, latency p50/p90/p99 (seconds and blocks), blocks during the step, transactions per block, bytes per block,
mempool maximum. In the overload steps only confirmed transactions per block and bytes per block are interpreted (the "lost" and
"rejections" columns there measure the worker's retry rule, not the chain).
Noise: the 6 repetitions of P give the step-to-step spread; a difference is stated only if it is larger than the range of the P repetitions
and has the same sign in at least 5 of 6 repetitions.

## Conditions
* Mac on AC and awake (caffeinate), Mac free disk >= 6 GB, VM free disk >= 6 GB and free memory >= 400 MB, otherwise stop.
* Kupo OFF, no demo, no page server, no load script, no other VM work; seedvm2/3/4 stay off.
* The registry is only changed in setup (and restored at the end by a trap): afterwards a utxo query shows the datum is exactly [A], and
  one demo batch from A is sent. The registry coin pointer `registry.ref` in the demo's work dir is updated.
* Keys of the measurement run live in /tmp/p3 in the container; never printed; the signing keys are deleted at the end.
* Invalid step (rerun, noted): the chain did not advance; a refusal that is not "mempool full"; the sampler missed more than 10 %.

## Not part of this run
Mainnet parameters; more or fewer than 100 readings per transaction (the maximum batch follows from arithmetic: (16,384 - overhead) /
bytes per reading); Kupo's cost; several gateways at once; CPU cost of the script (Plutus evaluation takes milliseconds and cannot
be seen on a 2-CPU VM next to three pools; only the execution units are reported).

## Limits to state in the report
Test network: 5 s blocks, fee 1 lovelace per byte, no reference-script fee, own parameters: only comparisons between the variants are
meaningful, not absolute rates. Pools, generator and node share 2 CPUs. One chain, one day. Submissions go to one pool only.
The reference-script variant looks cheaper here only because this chain charges nothing for reference scripts.
