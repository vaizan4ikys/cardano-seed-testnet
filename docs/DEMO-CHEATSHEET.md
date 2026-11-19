# Demo cheat sheet (one page, print it)

Sensors -> gateway -> smart contract (only approved gateways get in) -> chain -> Kupo -> web page.
Full guide: [`experiments/demo/README.md`](../experiments/demo/README.md). Install: [`INSTALL.md`](INSTALL.md). Questions: [`FAQ.md`](FAQ.md).

## The commands (in the VM, folder `~/cardano-seed-testnet`)

| # | When | Command |
|---|---|---|
| 1 | once, after install | `./install.sh --check` (every line PASS) |
| 2 | no chain yet, or chain dead | `./experiments/demo/fresh.sh --yes` (new chain + contract + registry, several minutes) |
| 3 | the day before | `./experiments/demo/demo.sh` (rehearsal: the whole demo, steps 0 to 6, all PASS) |
| 4 | **5+ minutes BEFORE the talk** | `./experiments/demo/demo.sh --prepare` (preflight, page, GW01 with 10 sensors; ends with "READY"). Open the page |
| 5 | **IN the talk** | `./experiments/demo/demo.sh --show` (the 4 live steps, about 1.5 to 2 min; nobody presses a key) |
| 6 | **AFTER the talk** | `./experiments/demo/demo.sh --step 6` (clean stop; registry back to GW01 approved, GW02 not) |
| 7 | the end of the day | `./stop.sh` (removes the chain containers) |

Keep a second terminal open with the tunnel, then open <http://127.0.0.1:8088>:
Windows (PowerShell) `ssh -p 2222 -L 8088:127.0.0.1:8088 <user>@127.0.0.1`; Mac (Terminal) `ssh -L 8088:127.0.0.1:8088 <user>@<vm-address>`.
Quick health check any time: `./experiments/demo/demo.sh --step 0` (all PASS = ready). If `--prepare` complains about leftover processes: `--step 6` first.
Do not suspend the VM or let the computer sleep (Mac: `caffeinate -d` in a Terminal window).

## The live part (`--show`), step by step

The talk is 5 minutes, the live part 1.5 to 2 minutes: about 25 s per step, one or two sentences. Under the header the page has three big buttons (Sensors, Trust, Details)
and a box **"Live demo - step N of 4"** with 4 progress bars and one line of what is happening. **The page switches between Trust and Sensors by itself**:
you do not click and you do not need the terminal. (Before: "No demo running"; after: "Live demo finished" for 2 minutes.)

Before the talk (`--prepare`): the page shows GW01 "Approved", "Sensors live 10 of 10", header "Approved gateways 1 of 2". Say a short intro: "Sensors send readings to a gateway, the gateway writes them to a blockchain, a smart contract decides who may write."

| Step | What appears on the page (by itself) | Say |
|---|---|---|
| 2 GW02 is refused (~10 s) | **Trust**: GW02 "Not approved - its data is refused", 0 batches | "A second gateway sends, but it is not on the list. The contract refuses it; nothing of it reaches the chain." |
| 3 Administrator approves GW02 (~25 s) | **Trust**: GW02 turns Approved, header 2 of 2. **Sensors**: a GW02 group with 5 cards (AGRI_011 ... AGRI_015) next to GW01's AGRI_001 ... AGRI_010 | "One transaction puts GW02 on the list. From now on both gateways write." |
| 4 Administrator revokes GW01 (~40 s) | **Trust**: GW01 Not approved, header 1 of 2. **Sensors**: after 30 s GW01's 10 sensors turn Silent, GW02's stay live | "GW01's batches are refused now, so its sensors go silent: that is the alarm. GW02 keeps writing." |
| 5 GW01 approved again (~20 s) | GW01 Approved, header 2 of 2; next batches go through, its sensors wake up | "One transaction and GW01 is back. The administrator controls who may write, while the system runs." |

At the end the terminal prints "the live part took N s" and everything keeps running for questions (click a card for the graph, **Verify** on a batch in Trust).
"Readings stored permanently" grows only when batches turn Final (about 5 minutes after the first batch). That is why `--prepare` runs 5+ minutes early.

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
3. Block number does not move (red): run `./experiments/demo/demo.sh --step 0`. If the VM was paused more than about 15 minutes the chain is dead: `--step 6`, then `fresh.sh --yes`. Show the **Details** view or talk about the architecture while it runs.
4. "Readings stored permanently" is 0: normal in the first 5 minutes (that is why `--prepare` runs early). Show Trust -> "Settling n / 60".
5. A step shows FAIL: read the `hint:` line below it, repeat only that step with `./experiments/demo/demo.sh --step N`. To stop at once press Ctrl-C (it also puts the registry back).
