# Multisite results

Measured on 13 November 2026 on the 5 s test chain (3 pools on seedvm), with the 3-VM mode: site 1 = seedvm2 (GW03),
site 2 = seedvm3 (GW04), site 3 = seedvm4 (GW05). Each site had its own Cardano node container, its own wallet
(100 test ADA plus 10 test ADA collateral) and 10 simulated sensors at 1 reading per second. Gateway settings:
B = 100 readings per batch, T = 10 s. Registry: GW01 (the demo gateway on seedvm) plus the three site gateways.
The gateway waits until a batch is in a block before it sends the next one (one unconfirmed batch at a time).
Raw samples: `results/test1.csv`, `results/test5.csv`. Logs of tests 3 and 4 were read on the VMs and are not
stored here; the numbers below were copied from them.

## Test 1: normal run (20 minutes, 12:12-12:30 UTC)

| what | result |
|---|---|
| batches per site gateway | about 118 each (GW03 9 -> 117, GW04 9 -> 117, GW05 9 -> 117 in the sampled 18 minutes) |
| sensors live on the page | 40 of 40 the whole time |
| warnings, rolled-back batches | 0, 0 |
| batch written -> batch in a block (from the gateway logs) | median 5 s at every site; p90 16 / 13 / 14 s; max 25 / 23 / 30 s |
| lost batches | 0 (every batch sent at a site was on the page, receipts = batches) |

The long tail (p90, max) comes from the one-batch-in-flight rule: when a block is late, the next batch waits for it.

## Test 3: revoke one site and enrol it again (12:30-12:34 UTC)

* 12:30:50 the administrator revoked GW04 (the registry change was in a block 1.9 s later).
* 12:30:52 the first batch of GW04 was refused by the contract. In about 2 minutes 14 batches (about 1,400 readings)
  were refused and moved to `dead/`: they never reach the chain, as designed.
* GW03 and GW05 went on without interruption. The page showed the 10 sensors of GW04 as silent.
* 12:32:43 GW04 was enrolled again (took 20 s this time; usually 1-2 s). Its next batches went through and all 40
  sensors were live again. Site 1 had a short backlog (6 pending batches) right after the registry change and caught
  up by itself.

## Test 4: one site cut off the network for 5 minutes (site 3, 100 % packet loss on its node)

| setting | lost | what happened |
|---|---|---|
| default `--max-tries 5` | 15 batches (about 1,500 readings, batch numbers 144-158) | The first batch stayed in the local node's mempool. Every next batch failed with "All inputs are spent" (its input was the change of the unconfirmed batch) and went to `dead/` after 5 tries. After reconnecting, the 21 pending batches were sent at about one per 2-5 s. |
| patient `--max-tries 1000` (`MAXTRIES=1000 ./multisite.sh gwrestart 3`) | 0 | 30 batches were waiting at the reconnect (12:50:06). All were on the chain, in order, 5.5 minutes later (12:55:37). Receipts = batches on the chain (255). |

Conclusion: with the default setting a gateway loses data during a network outage of more than about 30 seconds.
For real sites the gateway should use a patient retry setting (or allow several unconfirmed batches in flight).

## Test 5: load (stopped early)

Only the first stage ran (10 sensors per site): backlog 0-2 batches. The 20 and 30 sensors per site stages were not
run (the test was stopped on request). Expected ceiling from the one-batch-in-flight rule: about one batch per block
per gateway, i.e. roughly 100 readings per 5-6 s, about 15-20 readings per second per gateway.

## One machine (19 November 2026)

`SITES=local` mode (all three site nodes on the chain VM, seedvm, 4 GB RAM): setup about 20 s; after 3 minutes
10 batches per site gateway on the page; each site node used about 52-70 MB RAM and each gateway or sensor process
11-13 MB; available RAM went from 2.88 GB to about 2.55 GB. Revoke/enrol and cut/uncut behaved as in tests 3 and 4
(with the default retry setting the cut produced 2 dead batches). See README.md for the commands.
