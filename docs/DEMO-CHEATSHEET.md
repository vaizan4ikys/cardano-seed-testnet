# Demo cheat sheet (one page, print it)

Sensors -> gateway -> smart contract (only approved gateways get in) -> chain -> Kupo -> web page.
Full guide: [`experiments/demo/README.md`](../experiments/demo/README.md). Install: [`INSTALL.md`](INSTALL.md). Questions: [`FAQ.md`](FAQ.md).

## The 6 commands (in the VM, folder `~/cardano-seed-testnet`)

| # | When | Command |
|---|---|---|
| 1 | once, after install | `./install.sh --check` (every line PASS) |
| 2 | no chain yet, or chain dead | `./experiments/demo/fresh.sh --yes` (new chain + contract + registry, several minutes) |
| 3 | 10+ minutes before the audience | `./experiments/demo/demo.sh --yes` (rehearsal, no pauses, about 5 min, all PASS) |
| 4 | the presentation | `./experiments/demo/demo.sh` (press Enter before each step) |
| 5 | clean stop (also after Ctrl-C) | `./experiments/demo/demo.sh --step 6` |
| 6 | the end of the day | `./stop.sh` (removes the chain containers) |

Keep a second terminal open with the tunnel, then open <http://127.0.0.1:8088>:
Windows (PowerShell) `ssh -p 2222 -L 8088:127.0.0.1:8088 <user>@127.0.0.1`; Mac (Terminal) `ssh -L 8088:127.0.0.1:8088 <user>@<vm-address>`.
Quick health check any time: `./experiments/demo/demo.sh --step 0` (all PASS = ready).
Do not suspend the VM or let the computer sleep (Mac: `caffeinate -d` in a Terminal window).

## The demo, step by step (plan 10-15 min with talking)

| Step | Click on the page | Say |
|---|---|---|
| 0 Preflight | nothing | "We check that the chain makes blocks, the indexer is caught up, the clock is right, and that gateway A is on the registry and B is not." |
| 1 Page | open the page; click **Trust** | "The page keeps no data of its own, it reads the chain. GW01 is approved, GW02 is not. This list is stored on the blockchain. Header: 1 of 2." |
| 2 GW01, 10 sensors | **Sensors**: click a card (graph). **Trust**: click **Verify** on a batch | "10 sensors, one reading per second each. Every 10 s the gateway writes one transaction; the contract checks that the gateway is on the list. A batch is Settling, and Final after 60 blocks, about 5 minutes." |
| 3 GW02: refused, then approved | **Trust**: GW02 "Not approved", 0 batches; after the enrolment "Approved", header 2 of 2, its batches appear. **Sensors**: a GW02 group with 5 cards (AGRI_011 ...) | "GW02 builds the same kind of transaction. The contract refuses it; nothing of GW02 is on the chain. Now the administrator approves GW02 with one transaction: from now on both gateways write." |
| 4 Revoke and enrol | **Trust**: GW01 turns Not approved, header 1 of 2; after 40 s GW01's sensors turn Silent, GW02's stay live. Then Approved again, 2 of 2 | "The administrator removes GW01 from the list. Its batches are refused now, those readings are lost; GW02 keeps writing. Now we enrol GW01 again, and its sensors wake up." |
| 5 One sensor silent | **Sensors**: "Sensors live 9 of 10", one card Silent (after 40 s) | "AGRI_003 stops sending. The page hears nothing for 40 s and shows Silent. The other nine carry on." |
| 6 Stop | nothing | "Everything the demo started is stopped. The registry is as before: GW01 approved, GW02 not." |

"Readings stored permanently" grows only when batches turn Final (about 5 minutes after the first batch). That is why you rehearse first.

## Numbers worth quoting (test chain, not mainnet)

| Number | Where it comes from |
|---|---|
| A reading is in a block after about 6 s (6.1 s average). It is final (60 blocks deep) after about 310 s (295 to 332 s, 12 transactions). | [`measurement-report.html`](measurement-report.html), section 8 |
| A batch of 100 readings with the contract is a 2,289-byte transaction with a fee of 10,536 lovelace (3 keys on the list). Without contract: 1,264 bytes, 2,263 lovelace. The test chain charges 1 lovelace per byte; mainnet is different. | [`PHASE3-RESULTS.md`](../experiments/contract/PHASE3-RESULTS.md), Part A |
| One block (65,536 bytes) holds 28 such batches. At 6.7 batches per second offered, the chain delivered 489 readings per second (median) with the median wait 11.8 s. | [`PHASE3-RESULTS.md`](../experiments/contract/PHASE3-RESULTS.md), Part B |
| A revoke is in a block after 1 to 11 s (5.5 s in the demo rehearsal). A transaction prepared before is refused. | [`PHASE0-NOTES.md`](../experiments/contract/PHASE0-NOTES.md), task 3; [`demo/README.md`](../experiments/demo/README.md), Timings |

## If something goes wrong

1. Page says "The server does not answer": wait 10 s, check that the tunnel window is open, then `curl -s http://127.0.0.1:8088/health` in the VM.
2. "Indexer unreachable" (yellow): `cd ~/cardano-seed-testnet/experiments/pipeline && ./kupo.sh start`. The page recovers by itself.
3. Block number does not move (red): run `./experiments/demo/demo.sh --step 0`. If the VM was paused more than about 15 minutes the chain is dead: `--step 6`, then `fresh.sh --yes`. Show the **Details** tab or talk about the architecture while it runs.
4. "Readings stored permanently" is 0: normal in the first 5 minutes. Show Trust -> "Settling n / 60".
5. A step shows FAIL: read the `hint:` line below it, repeat only that step with `./experiments/demo/demo.sh --step N`. To stop at once press Ctrl-C (it also puts the registry back).
