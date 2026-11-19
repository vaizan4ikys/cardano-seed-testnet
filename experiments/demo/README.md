# The demo: sensor data on a private Cardano chain (presenter's guide)

This is the guide for the person who runs and presents the demo. To install everything first, see
[`docs/INSTALL.md`](../../docs/INSTALL.md) (Ubuntu VM on a Windows PC or a Mac, from nothing to a running demo).

## What the demo shows

Simulated sensors send readings to a gateway. The gateway packs them into a batch and writes the batch as metadata of
one Cardano transaction, signed with the gateway's own key. A **smart contract** (a small program on the chain, written in Aiken)
lets the transaction in only if the gateway's key is on a list, the **registry**, kept on the chain by an administrator.
A web page reads the chain back (through Kupo, an indexer) and shows the sensors, who may send data, and how safe the stored data is.

The demo proves four things:

1. **An approved gateway's data arrives** on the chain and on the page.
2. **A gateway that is not approved is refused** by the contract: its data never reaches the chain.
3. **The administrator can revoke and enrol a gateway while the system runs**, and the page shows the change.
4. **The page notices when a sensor goes silent.**

## Files

| file | what |
|---|---|
| `demo.sh` | the demo: `--prepare` before the talk, `--show` in the talk (4 live steps), `--step 6` after; without option the whole rehearsal (steps 0 to 6) |
| `fresh.sh` | from nothing to a ready demo: new chain, contract, registry, gateway wallets. Tested end to end on 13 November 2026 |
| `remote.sh` | helper that starts/stops the demo processes, keeps a pid file, counts log lines |
| `in-container/p1-list.sh` | shows who is on the registry list (runs inside the pool-1 container) |
| `in-container/p1-fund.sh` | funds the wallets of gateway A and B once (used by `fresh.sh`) |
| `../contract/in-container/p1-enroll.sh`, `p1-revoke.sh` | administrator: add / remove a gateway on the list |
| `../pipeline/` | sensors, gateway, Kupo script, page server and the page ([README](../pipeline/README.md)) |

## How to run

### Main case: on the Ubuntu VM (local mode)

On Linux the scripts run in **local mode**: the chain, Kupo, the gateways, the sensors and the page server are all on the machine you type on.
All commands are typed in the VM terminal (or over ssh from your PC or Mac), in `~/cardano-seed-testnet`:

```
./experiments/demo/fresh.sh --yes      # only when there is no chain yet, or the chain is dead: new chain + contract + registry
./experiments/demo/demo.sh --prepare   # BEFORE the talk, 5+ minutes early: preflight + page + gateway GW01 with 10 sensors; ends with "READY"
./experiments/demo/demo.sh --show      # IN the talk: the 4 live steps one after the other (about 1.5 to 2 minutes), nobody presses a key
./experiments/demo/demo.sh --step 6    # AFTER the talk: clean stop (also after an interrupted run)
./experiments/demo/demo.sh             # rehearsal: the whole demo, steps 0 to 6, PASS/FAIL for every check
./experiments/demo/demo.sh --step 3    # only one step (starts what it needs, stops it at the end; add --keep to leave it running)
./stop.sh                              # stop the chain (removes the containers)
```

There are no pauses: `demo.sh` never waits for a key. (`--yes` is still accepted and means the same as no option.)
`--prepare` refuses to start while an earlier run is still running (the preflight reports leftover processes): run `--step 6` first.
`--show` first puts the start state back (gateway GW02 stopped and not on the list, GW01 on the list and sending); this is not counted in the live time.
At the end it prints `the live part took N s` and leaves everything running for questions.

The page is at <http://127.0.0.1:8088> **inside the VM**. Open an ssh tunnel in a second terminal window and keep it open
(`<user>` is your VM user name):

```
ssh -p 2222 -L 8088:127.0.0.1:8088 <user>@127.0.0.1      # Windows, VirtualBox (2222 = its port forwarding to the VM's ssh)
ssh -L 8088:127.0.0.1:8088 <user>@<vm-address>           # Mac, VMware Fusion (<vm-address>: hostname -I in the VM)
```

Then open <http://127.0.0.1:8088> in the browser of your PC or Mac.
In local mode `demo.sh` opens no tunnel; step 1 prints `>>> open http://127.0.0.1:8088 in the browser <<<` and the ssh command of the tunnel.
`--open` does nothing in local mode on Linux (it only works on macOS; the script says so). The page was checked through a tunnel (`http://127.0.0.1:8089` -> VM port 8088): it answered 200 and `/api/state` showed the registry as known.

Step 0 refuses to go on when a check fails and prints a hint. The rehearsal (no option) stops everything it started when it ends, also on Ctrl-C;
`--prepare` and `--show` leave everything running (stop it with `--step 6`). If the demo is interrupted between the revoke and the new approval of GW01 (steps 4 and 5), the cleanup approves GW01 again.

**Before a presentation:** make sure the chain is alive (`./experiments/demo/demo.sh --step 0`, all `PASS`). A chain that stood still for more than
about 15 minutes (VM suspended, PC asleep) is dead: run `fresh.sh --yes` (see [`docs/INSTALL.md`](../../docs/INSTALL.md)).
Run `--prepare` at least 5 minutes before the talk (earlier is fine): batches become "final" only about 5 minutes after they were written
(60 blocks of about 5 s), so the page already shows numbers under "Readings stored permanently" when the audience looks.
The day before, run the rehearsal (`./experiments/demo/demo.sh`, no option) once and check that every step says `PASS`.

### Second case: from the Mac to `seedvm` (our own setup)

On the Mac the default is `CHAIN_HOST=seedvm`: the scripts run on the Mac and drive the VM `seedvm` over ssh; the page is reached through an ssh tunnel that `demo.sh` opens.
`CHAIN_HOST=local` forces local mode, `CHAIN_HOST=seedvm` (or another ssh alias) forces ssh mode (defaults: `local` on Linux, `seedvm` on the Mac, see `experiments/demo/host.sh`). `./experiments/demo/demo.sh --open` also opens the page in the Mac browser.
Everything in the guide below is the same in both modes; only where the logs and the work folders are is different (next section).

## Settings (environment variables)

| variable | default | meaning |
|---|---|---|
| `DEMO_T` | 5 | gateway batch time in seconds |
| `DEMO_B` | 100 | readings per batch (a batch goes out when it has B readings or after T seconds) |
| `DEMO_HOLD` | 3 | `--show`: seconds between two live steps, to look at the result |
| `DEMO_SILENT` | 30 | the page marks a sensor silent after this many seconds without a new reading from the chain (the server's own default is 90) |
| `PORT` | 8088 | page port (use another one if 8088 is busy, for example `PORT=8089 ./experiments/demo/demo.sh`) |
| `DEMO_CLOCK_STRICT` | 0 | `1` turns a clock difference between your machine and the chain machine into a FAIL (only for the Mac mode) |
| `SEED_EMULATOR` | `~/seed-emulator` | where the SEED Emulator clone is |
| `SEED_PYTHON` | `~/seed-venv/bin/python3` if it exists, else `python3` | the Python that runs seed-emulator (`run.sh`, preflight) |
| `AIKEN`, `KUPO_BIN` | in `~/tools` | paths of the Aiken and Kupo programs |
| `CHAIN_HOST` | `local` on Linux, `seedvm` on the Mac | where the chain runs |

## Where the logs and files are

On the machine that runs the chain (the VM in local mode, `seedvm` in Mac mode):

* Logs: `/tmp/demo-logs/<server|gwA|gwB|sensorsA|sensorsB>.log`
* Outboxes (batch files, and `dead/` for refused batches): `/tmp/demo-run-<time>/outboxA`, `outboxB` (not in the repo)
* The page server asks the registry coin through Kupo; it needs the files of the administrator in the container (`/tmp/p0n`)

## The page

Open it in the browser. It keeps no data of its own: everything is read from the chain through Kupo about every 2 seconds.

**Under the header:** on the left three big buttons, **Sensors**, **Trust** and **Details** (they replace the old small tabs). On the right the box **"Live demo - step N of 4"**
with 4 progress bars, the title of the step and one line of what is happening right now. `demo.sh` posts this text to the page.
During the live steps the page **switches to the matching view (Trust or Sensors) by itself**, so the presenter does not need to click or to look at the terminal.
When no demo runs the box says "No demo running"; after `--show` it says "Live demo finished" for 2 minutes. You can still click the buttons at any time.

**Header (always visible)**

| number | meaning |
|---|---|
| Sensors live | sensors that sent a new reading in the last `DEMO_SILENT` seconds, out of all sensors seen on the chain (for example "10 of 10") |
| Readings stored permanently | readings in batches that are **final**: 60 blocks deep, so nobody can change or remove them any more. It starts to grow about 5 minutes after the first batch |
| Approved gateways | gateways on the registry list, out of the gateways the page knows by name. Read from the chain. In the live demo: "1 of 2" at the start, "2 of 2" after step 3, "1 of 2" after the revoke in step 4, "2 of 2" after step 5 |

Top right: "Blockchain connected - block N" (green) or "not reachable" (red).

**View Sensors** (for everyone)

* Cards grouped by gateway. Each gateway has a badge: **Approved** or **Not approved** (from the registry on the chain) and "N of M sensors live".
* Each card is one sensor and one kind of measurement (temperature, humidity, soil moisture): the latest value, a small curve and a badge:
  **Live**, **Silent** (no new reading for more than `DEMO_SILENT` seconds), or **Out of range** (the latest value is outside the limits, e.g. temperature below -40 or above 60 degrees; the simulated sensors send about 2 % such values).
* **Click a card** to see the graph at the top: the last readings, lowest / average / highest. Move the mouse over the line to see a value, its time and its reading number (the graph pauses while the mouse is on it).
* Every value in this view was read back from the blockchain, not from the sensor.

**View Trust** (for the questions "can I believe this?")

* **Who may send data?** A table of gateways: **Approved** or **Not approved**, batches stored, readings stored, time of the last data. The approved list is stored on the chain, read through Kupo every 3 seconds. A gateway that is not approved is refused by the contract.
* **Is the stored data safe?** A batch is first **settling** ("Settling 12 / 60": it is in a block, but a rare rollback could still move it) and after 60 more blocks **final**. Three counters (final, settling, rolled back) and a bar.
* **Latest batches**, with a **Verify** button for each: it opens the proof of that batch: the transaction id, the block and how many blocks are on top of it, the **fingerprint of the data**
  (a SHA-256 hash of the exact data of the batch: change one value and the fingerprint changes), who signed it, and in plain words what it proves ("these N readings were written to the blockchain by an approved gateway"). Click **Hide** to close it.

**View Details** (technical): chain tip, Kupo status, server time, number of batches and readings, number of keys in the registry; the table of the latest batches with depth bars (and warnings, for example a batch that says it is from another gateway than the one that signed it); the table of gateways with wallet addresses and receipt counters. (A receipt is a token that only an approved gateway can mint, one per batch.)

## What to say, step by step

The whole presentation is 5 minutes; the live part is about 1.5 to 2 minutes. That leaves about 25 seconds for each of the 4 live steps: say one or two sentences, then let the page speak.

### Before the talk (5+ minutes early)

`./experiments/demo/demo.sh --prepare` runs step 0 (preflight: the chain makes blocks, the indexer is caught up, the clock is right, the registry has GW01 on it and GW02 not)
and step 1 (the page server, in Mac mode the ssh tunnel, gateway GW01 approved, 10 sensors). It ends with `READY ...`.
Open the page. *You should see:* "Chain connected", GW01 "Approved", "Sensors live 10 of 10", header "Approved gateways 1 of 2", the box "No demo running".
Leave it alone: after about 5 minutes the first batches are "Final" and "Readings stored permanently" shows a number.
(A fresh chain has no old sensors; sensors from earlier runs turn Silent after 30 s.)

### In the talk: `./experiments/demo/demo.sh --show`

Start it in the terminal, then look at the page: it moves by itself and the box "Live demo - step N of 4" tells what happens. Nobody presses a key.
A short intro before you start (the first seconds are the start state being put back, not counted): "Sensors send readings to a gateway; the gateway writes them to a blockchain; a smart contract decides who may write. The page reads everything back from the chain."

| Step | What the page shows by itself | What to say (short) |
|---|---|---|
| 2 GW02 is refused (~10 s) | switches to **Trust**: GW02 "Not approved - its data is refused", 0 batches; GW01 sends | "A second gateway starts sending, but it is not on the list. The contract refuses its data; nothing of it reaches the chain." |
| 3 The administrator approves GW02 (~25 s) | **Trust**: GW02 turns **Approved**, header "2 of 2". Then **Sensors**: a second group with 5 sensors (AGRI_011 ... AGRI_015) next to GW01's AGRI_001 ... AGRI_010 | "One transaction puts GW02 on the list, stored on the chain. From now on both gateways write." |
| 4 The administrator revokes GW01 (~40 s) | **Trust**: GW01 turns **Not approved**, header "1 of 2". **Sensors**: after 30 s GW01's 10 sensors turn **Silent**; GW02's stay live | "The administrator removes GW01. Its batches are refused now, so the page stops hearing from its sensors: the silent alarm. GW02 is not affected." |
| 5 GW01 is approved again (~20 s) | GW01 **Approved**, header "2 of 2"; its next batches go through and its sensors wake up (**Live**) | "One transaction and GW01 is back; its sensors are live again. The administrator controls who may write, while the system runs." |

Between the steps there is a 3 s hold (`DEMO_HOLD`). At the end the terminal prints `the live part took N s`; the page shows "Live demo finished" and everything keeps running.
Use the time for questions: click a sensor card (graph), **Verify** on a batch in Trust (transaction, block, fingerprint of the data), or look at Details.
"Readings stored permanently" grows only when batches turn final (60 blocks, about 5 minutes) - that is why `--prepare` runs early.

### After the talk

`./experiments/demo/demo.sh --step 6`: "Everything the demo started is stopped; the registry is back to GW01 approved, GW02 not."

## Timings

The table below was measured with the **old 6-step flow** (batch every 10 s, silent after 40 s, one pause per step, with the old step "one sensor goes silent").
The new live part (`--show`, batch every 5 s, silent after 30 s) is designed for 1.5 to 2 minutes; measured on 19 November 2026 on an Ubuntu 20.04 arm64 VM (2 CPUs, 4 GB RAM), local mode: 1 min 48 s, 1 min 29 s and 1 min 6 s in three runs, all steps PASS (the time depends on when the next blocks come). Per step: 2 refused 7-8 s, 3 approve GW02 9-25 s, 4 revoke GW01 32-49 s (the 30 s silent limit), 5 approve again 4-28 s; `--prepare` 25-60 s; `--step 6` 14-44 s.

Rehearsal on the live chain, 12 November 2026, Mac mode, 10 sensors, B=100, T=10 s:

| step | seconds | what takes the time |
|---|---|---|
| 0 preflight | 4-7 | waits for one new block (about every 5 s on average) |
| 1 page | 3-4 | |
| 2 gateway A | 39-45 | 3 batches, one per 10 s, each a few seconds from submit to block |
| 3 gateway B | 30-31 | 2 refused batches (the old flow; the new flow is timed above) |
| 4 revoke / enrol | 57-72 | revoke in a block 5.5 s, silent after about 15 s more, enrol 0.8-1.9 s (1.4-6 s measured by hand), new batches after about 18 s |
| 5 silent sensor | 63-79 | 20 s until the sensor stops + batch time + 40 s silent limit |
| 6 stop | 3-22 | gateways write out their last batch |

Whole old demo without pauses: about 4-5 minutes.

The same rehearsal in local mode on an Ubuntu 20.04 arm64 VM with 2 CPUs and 4 GB RAM (19 November 2026, old flow, `demo.sh --yes`, all steps PASS, 5 min 15 s in total):
step 0 4 s, step 1 1 s, step 2 102 s, step 3 29 s, step 4 78 s, step 5 71 s, step 6 30 s. Steps 2 and 4 to 6 are slower than in the table above (Mac mode).

## If something goes wrong during the presentation

Stay calm: nothing here can damage the chain. The quick answers:

| What you see | What to do |
|---|---|
| The page shows a banner "The server does not answer" | Wait 10 s. If it stays: is the tunnel window still open? Reopen it. Check in the VM: `curl -s http://127.0.0.1:8088/health` |
| Page shows "Indexer unreachable" (yellow banner) | Kupo stopped: `cd ~/cardano-seed-testnet/experiments/pipeline && ./kupo.sh start`; the page recovers by itself |
| "Blockchain not reachable" in red, block number does not move | The chain stands still. Say so, run `./experiments/demo/demo.sh --step 0` in another window to see why. If it is dead (VM was paused): `./experiments/demo/demo.sh --step 6`, then `./experiments/demo/fresh.sh --yes` takes several minutes: show the **Details** view or the architecture while you wait |
| Sensors do not show up after `--prepare` | Batches come every 5 s, give it 30 s. Check `tail -20 /tmp/demo-logs/gwA.log` |
| A step shows `FAIL` | Read the `hint:` line below it. The script goes on with the next step; you can repeat a single step with `./experiments/demo/demo.sh --step N`. `--prepare` that says the preflight found leftover processes: run `--step 6` first |
| The live box on the page does not move | Look at the terminal: is `--show` still running? The box only follows `demo.sh`; the views still work by clicking the buttons |
| The views look empty / "No batches on the chain yet" | The chain is new and nothing was sent yet. Run `--prepare` and wait one minute |
| "Readings stored permanently" stays at 0 | Normal in the first 5 minutes: batches turn final only 60 blocks (about 5 minutes) after they were written. Show **Trust** -> "Settling n / 60". Run `--prepare` 5+ minutes before the talk so that the first batches are final |
| You must stop at once | Ctrl-C in the demo window: it stops everything it started and repairs the registry list. Or `./experiments/demo/demo.sh --step 6` |

## What to do on a FAIL (details)

* **Chain stalled** (step 0: "tip not advancing"): `NET=1 ./scripts/check.sh` (all pools should show the same tip); `docker ps | grep Pool` (about 35 containers).
  If it does not come back: `./experiments/demo/fresh.sh --yes` (new chain, takes minutes).
* **Kupo behind or not running:** `cd ~/cardano-seed-testnet/experiments/pipeline && ./kupo.sh status`; start it with `./kupo.sh start`.
  After a new chain: `./kupo.sh wipe` first (`fresh.sh` does it).
* **Page empty / "unknown signer":** check `curl -s http://127.0.0.1:8088/health`; the wallet addresses in
  `experiments/pipeline/gateways.json` must be those of the current gateways A and B (step 0 checks it; `fresh.sh` writes them).
  Page slow after a long time: restart it (`--step 6`, then `--prepare` again); it rebuilds from Kupo.
* **"Approved gateways" shows "-" or the Trust view says "The list could not be read from the chain":** the page could not read the registry coin.
  Check that `/tmp/p0n` exists in the pool-1 container (`fresh.sh` creates it) and that Kupo is caught up.
* **Gateway stuck** (no `sent:` lines): `tail -20 /tmp/demo-logs/gwA.log`. "submit command exit 1" means the transaction could not be built or sent:
  usually the chain is slow or the wallet is empty. Batches that fail 5 times go to `dead/` and are NOT on the chain.
* **Port busy:** find the owner with `ss -ltnp | grep 8088` and stop it, or use another port: `PORT=8089 ./experiments/demo/demo.sh` (change the port in the tunnel and the browser, too;
  8080 can be taken by the SEED Internet map).
* **Leftover processes:** `./experiments/demo/demo.sh --step 6`; by hand: `cat /tmp/demo-logs/pids` and kill them.
* **Mac mode only: VM clock.** In Mac mode the VM clock can differ from the Mac clock (step 0 prints a WARN). Everything of the demo uses the VM clock only, so this does not matter; times on the page and in the logs are VM times.
  Do NOT set the VM clock by hand while the chain runs (the nodes would disagree with the slot time); only after a stop of the chain.

## Reset

* Registry back to the start state (A enrolled, B not):
  `docker exec -e P0_DIR=/tmp/p0n $(docker ps --format '{{.Names}}' | grep Pool-1-) bash /tmp/p0-scripts/p1-enroll.sh 42 A`
  and the same with `p1-revoke.sh 42 B`. Show the list with `p1-list.sh 42`. Both scripts can be run again without harm.
  (In Mac mode put `ssh seedvm "..."` around the command.)
* Clear the outboxes and logs, after `--step 6`: `rm -rf /tmp/demo-run-* /tmp/demo-logs`.
* The batches already written stay on the chain forever; the page shows them again after a restart. Only a new chain
  (`fresh.sh`) gives an empty page.

## Fresh chain: `fresh.sh`

`./experiments/demo/fresh.sh --dry-run` prints every command and changes nothing. `./experiments/demo/fresh.sh` asks you to type "yes"; `--yes` does not ask.
It **destroys the running chain** and does: new chain with protocol version 9 (`run.sh`), waits for blocks, Kupo wipe + start, copies the contract project and scripts,
administrator + gateway keys and funding (`p0-admin.sh`), Aiken build and parameters (`p0-aiken.sh`), the one-shot registry mint with A enrolled
(`p0-registry.sh`), funds the wallets of A and B (`p1-fund.sh`), writes the new wallet addresses into `experiments/pipeline/gateways.json`, then runs the preflight.
It was run for real, end to end, on 13 November 2026 (every step OK, preflight all PASS, the demo passed on the new chain).
The local mode for the Ubuntu VM (`CHAIN_HOST=local`, the default on Linux) was run for real on 19 November 2026 on an Ubuntu 20.04 arm64 VM (2 CPUs, 4 GB RAM) as a new user:
`fresh.sh --yes` 4 min 25 s with every step OK and the preflight all PASS, then `demo.sh --yes` (old flow) all PASS (5 min 15 s). Not run on amd64. See [`docs/INSTALL.md`](../../docs/INSTALL.md).

## Limits (to say honestly)

* **The administrator key is the weak point.** It sits in the pool-1 container (`/tmp/p0n/admin.skey`). Anyone with docker
  access on the machine can enrol or revoke any gateway. One key, no second signature, no delay.
* **The contract proves authorization, nothing more.** It checks that the transaction minting a receipt is signed by a key
  on the list. It does not stop anybody from sending a transaction with junk metadata without a receipt (any wallet can do
  that on this chain). The page ignores transactions without a receipt token. Caution: unless the page server is started
  with `--receipt-policy <policy id>`, a receipt of ANY policy counts; the demo does not set it.
* **Identity is the signer address** (output #0 of the transaction). There is no IP or device identity. The gateway name
  inside the metadata is only shown as "says ..."; a mismatch is flagged.
* **Revocation is not retroactive and not instant.** Batches that are already in a block stay. A transaction built before
  the revocation can still get into the same block. After the revoke, new batches are refused; their readings are lost
  (dead-letter) unless somebody re-sends them.
* The "silent" alarm is on the server clock and only means "no new reading arrived from the chain for N s".
  The demo uses 30 s to be quick; with the real batch time of 30 s use 90 or more (the server default).
* Private chain on one VM, simulated sensors, TCP lines instead of MQTT; the depth of old batches (from before the page server started) is an estimate.
* "Final" here means 60 blocks (k) deep on this private chain with 3 pools; it is not the security of a public chain.
* Each registry change costs a few hundred lovelace of the registry coin (about 5 ADA); thousands of changes are possible.
* What the contract costs (size, fees, how many batches fit in a block) is measured in [`../contract/PHASE3-RESULTS.md`](../contract/PHASE3-RESULTS.md);
  what it does and how it was tested is in [`../contract/PHASE0-NOTES.md`](../contract/PHASE0-NOTES.md).
