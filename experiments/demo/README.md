# Leader demo: sensor data on a private Cardano chain

Written 12 November 2026. Everything runs on the Mac; the chain, Kupo, the gateways, the sensors and the page server
run on seedvm. The Mac drives seedvm over ssh and looks at the page through an ssh tunnel.

## What the demo shows (in one paragraph)

Simulated sensors send readings to a gateway. The gateway packs them into a batch and writes the batch as metadata of
one Cardano transaction, signed with the gateway's own key. A smart contract lets the transaction in only if the
gateway's key is on a list (the registry) kept by an administrator. A web page reads the chain back (through Kupo) and
shows the sensors, the batches, how deep each batch is buried, and which gateway wrote it.
The demo proves four things: (1) an enrolled gateway's data arrives on the chain and on the page, (2) a gateway that
is not enrolled is refused by the contract, (3) the administrator can revoke and enrol a gateway while the system
runs, (4) the page notices when a sensor goes silent.

## Files

| file | what |
|---|---|
| `demo.sh` | the 6-step demo (Mac) |
| `fresh.sh` | from a new chain to a ready demo (Mac). **Not tested end to end**, see below |
| `remote.sh` | helper that runs on seedvm: start/stop processes, pid file, log counts |
| `in-container/p1-list.sh` | shows who is on the registry list (run inside the pool-1 container) |
| `in-container/p1-fund.sh` | funds the wallets of gateway A and B once (used by `fresh.sh`) |
| `../contract/in-container/p1-enroll.sh`, `p1-revoke.sh` | administrator: add / remove a gateway on the list |

## How to run

```
cd ~/cardano-seed-testnet/experiments/demo
./demo.sh --open          # the whole demo, "press Enter" before every step, opens the page in the browser
./demo.sh --yes           # rehearsal: no pauses, prints PASS/FAIL for every check (about 4-5 minutes)
./demo.sh --step 3        # only one step (starts what it needs, stops it at the end; add --keep to leave it running)
./demo.sh --step 6        # clean stop (also after an interrupted run)
```

Step 0 refuses to go on when a check fails and prints a hint. Everything the demo starts is stopped when the script
ends, also on Ctrl-C; if step 4 is interrupted between revoke and enrol, the cleanup enrols A again.
Logs on seedvm: `/tmp/demo-logs/<server|gwA|gwB|sensorsA|sensorsB>.log`. Outboxes (batch files, `dead/`):
`/tmp/demo-run-<time>/outboxA`, `outboxB` on seedvm (not in the repo). Page: <http://127.0.0.1:8088>.

Settings (environment variables): `DEMO_T` (gateway batch time, 10 s), `DEMO_B` (readings per batch, 100),
`DEMO_SILENT` (page marks a sensor silent after this many seconds, 40; the server's own default is 90),
`PORT` (page port, 8088), `DEMO_CLOCK_STRICT=1` (VM/Mac clock difference becomes a FAIL).

## What to say, step by step

0. **Preflight.** "Before we start we check that the chain makes blocks, that the indexer is caught up, that the clocks
   agree, that the registry has gateway A on it and gateway B not."
1. **Page and tunnel.** "This is the page. It keeps no data of its own: it reads the chain through Kupo. Chain tip
   moves, Kupo is ok." (Old sensors from earlier runs may be on the page; they turn silent after 40 s. A fresh chain
   has none.)
2. **Enrolled gateway GW01, 10 sensors.** "10 sensors, one reading per second each. Every 10 s the gateway writes one
   transaction. Watch: a new batch appears in the list, its depth bar grows block by block until it is final, the
   receipts counter of GW01 goes up by one per batch, the sensor values move." (Receipt = a token the contract lets
   only enrolled gateways mint, one per batch.)
3. **Gateway GW02, not enrolled.** "GW02 has its own wallet and key and builds the same kind of transaction. The
   contract refuses it. Here is the line from the gateway log. The batch goes to `dead/`. Nothing of GW02 is on the
   page."
4. **Revoke and enrol.** "The administrator removes GW01 from the list. GW01's sensors keep sending, but the batches
   are refused now (these readings are lost). After 40 s the page shows the sensors silent. Now we enrol GW01 again: the
   next batches go through and the sensors wake up."
5. **One sensor silent.** "AGRI_003 stops sending. The page does not hear from it any more and raises the silent alarm
   after 40 s; the others carry on."
6. **Stop.** "Everything the demo started is stopped; the chain and the registry are as before."

## Timings (rehearsal on the live chain, 12 November 2026, 10 sensors, B=100, T=10 s)

| step | seconds | what takes the time |
|---|---|---|
| 0 preflight | 4-7 | blocks come about every 1-3 s |
| 1 page + tunnel | 3-4 | |
| 2 gateway A | 39-45 | 3 batches, one per 10 s, each a few seconds from submit to block |
| 3 gateway B | 30-31 | 2 refused batches |
| 4 revoke / enrol | 57-72 | revoke in a block 5.5 s, silent after about 15 s more, enrol 0.8-1.9 s (1.4-6 s measured by hand), new batches after about 18 s |
| 5 silent sensor | 63-79 | 20 s until the sensor stops + batch time + 40 s silent limit |
| 6 stop | 3-22 | gateways write out their last batch |

Whole demo without pauses: about 4-5 minutes; with talking, plan 10-15 minutes.

## What to do if

* **Chain stalled** (step 0: "tip not advancing"): on seedvm `cd ~/cardano-seed-testnet && NET=1 ./scripts/check.sh`;
  `docker ps | grep Pool` (about 35 containers). If it does not come back: `./fresh.sh` (new chain, takes minutes).
* **Kupo behind or not running:** `ssh seedvm 'cd cardano-seed-testnet/experiments/pipeline && ./kupo.sh status'`; start with
  `./kupo.sh start`. After a new chain: `./kupo.sh wipe` first (fresh.sh does it).
* **Page empty / "unknown signer":** check `curl -s http://127.0.0.1:8088/health`; the wallet addresses in
  `experiments/pipeline/gateways.json` must be those of the current gateways A and B (step 0 checks it).
  Page slow after a long time: restart it (`--step 6`, then run again); it rebuilds from Kupo.
* **Gateway stuck** (no `sent:` lines): `ssh seedvm 'tail -20 /tmp/demo-logs/gwA.log'`. "submit command exit 1" means the
  transaction could not be built or sent: usually the chain is slow or the wallet is empty. Batches that fail 5 times go
  to `dead/` and are NOT on the chain.
* **Tunnel port busy:** `lsof -i :8088` and kill the old `ssh -L`, or use another port: `PORT=8089 ./demo.sh`
  (the same port is used on seedvm; 8080 is taken there by another program).
* **VM clock:** the VM clock is now about 9.8 hours behind the Mac (step 0 prints a WARN). Everything of the demo
  uses the VM clock only, so this does not matter; times on the page and in the logs are VM times. Do NOT set the VM
  clock by hand while the chain runs (the nodes would disagree with the slot time); only after a restart of the chain.
* **Leftover processes / port busy on seedvm:** `./demo.sh --step 6`; by hand:
  `ssh seedvm 'cat /tmp/demo-logs/pids'` and kill them.

## Reset

* Registry back to the start state (A enrolled, B not): 
  `ssh seedvm "docker exec -e P0_DIR=/tmp/p0n \$(docker ps --format '{{.Names}}' | grep Pool-1-) bash /tmp/p0-scripts/p1-enroll.sh 42 A"`
  and the same with `p1-revoke.sh 42 B`. Show the list with `p1-list.sh 42`. Both scripts are idempotent.
* Clear the outboxes and logs: after `--step 6`: `ssh seedvm 'rm -rf /tmp/demo-run-* /tmp/demo-logs'`.
* The batches already written stay on the chain forever; the page shows them again after a restart. Only a new chain
  (`fresh.sh`) gives an empty page.

## Fresh chain: `fresh.sh`

`./fresh.sh --dry-run` prints every command. `./fresh.sh` (asks for "yes") does: new chain with PV=9 (`run.sh`), waits
for blocks, Kupo wipe + start, copies the contract project and scripts, administrator + gateway keys and funding
(`p0-admin.sh`), Aiken build and parameters (`p0-aiken.sh`), the one-shot registry mint with A enrolled
(`p0-registry.sh`), funds the wallets of A and B (`p1-fund.sh`), writes the new wallet addresses into
`experiments/pipeline/gateways.json`, then runs the preflight.
**It is untested end to end**: it was only read, syntax-checked (`bash -n`) and run with `--dry-run`, because a real run
destroys the chain that the rehearsals use. Its pieces are the same scripts `p0.sh` already ran on this chain, except
`p1-fund.sh` (the funding block of `p0-write.sh`, copied) and the waiting loop. Expect to fix small things on the first real run.

## Limits (to say honestly)

* **The administrator key is the weak point.** It sits in the pool-1 container (`/tmp/p0n/admin.skey`). Anyone with docker
  access on seedvm can enrol or revoke any gateway. One key, no second signature, no delay.
* **The contract proves authorization, nothing more.** It checks that the transaction minting a receipt is signed by a key
  on the list. It does not stop anybody from sending a transaction with junk metadata without a receipt (any wallet can do
  that on this chain). The page ignores transactions without a receipt token. Caution: unless the page server is started
  with `--receipt-policy <policy id>`, a receipt of ANY policy counts; the demo does not set it.
* **Identity is the signer address** (output #0 of the transaction). There is no IP or device identity. The gateway name
  inside the metadata is only shown as "says ..."; a mismatch is flagged.
* **Revocation is not retroactive and not instant.** Batches that are already in a block stay. A transaction built before
  the revocation can still get into the same block. After the revoke, new batches are refused; their readings are lost
  (dead-letter) unless somebody re-sends them.
* The page's "silent" alarm is on the server clock and only means "no new reading arrived from the chain for N s".
  The demo uses 40 s to be quick; with the real batch time of 30 s use 90 or more (the server default).
* Private chain on one VM (4 GB), simulated sensors, TCP lines instead of MQTT; depths of old batches are estimates.
* Each registry change costs a few hundred lovelace of the registry coin (about 5 ADA); thousands of changes are possible.
