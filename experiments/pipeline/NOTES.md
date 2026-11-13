# pipeline notes

Written 12 November 2026. Everything here runs on the Mac only, Python 3 standard library. Nothing was run
against the chain.

## What exists

* `layout.py` metadata layout, size estimate (CBOR), checks, batch hash, splitting of too large batches.
* `sensor.py` N simulated sensors (AGRI_001.., kinds temperature/humidity/soil_moisture in turn), bounded random
  walk, out-of-range values (`--outlier-pct`, default 2), one sensor can go silent, sequence number per sensor,
  one JSON line per reading over TCP (or `--stdout`).
* `gateway.py` receives the lines, drops duplicates (same sensor + seq), batches by B or T, writes
  `outbox/batch-<n>-<hash>.json` + `.status` (pending/sent), calls the submit step (`dry` or `command`), keeps
  `outbox/state.json`. After a restart pending batches are submitted again. A batch that fails `--max-tries`
  submits (default 5) is moved to `outbox/dead/` and the later batches go on. `--tx-reserve` (default 1500)
  is the room kept in a transaction besides the metadata.
* `calc_size.py` the size table. `README.md` the layout and the hash rule.
* `test_pipeline.py` 31 tests: `python3 -m unittest` (about 5 s, includes an end-to-end run on localhost).

## 20-second dry demo

Two terminals, in this folder.

```
python3 gateway.py --B 20 --T 8 --listen-port 9100 --outbox outbox-demo --submit dry
python3 sensor.py --sensors 5 --interval 1 --duration 20 --port 9100 --silent-sensor AGRI_002 --silent-after 10
```

The gateway prints one line per batch (readings, bytes, hash, wait of the oldest reading). Stop it with Ctrl-C:
the readings still waiting are written as a last batch. Look at `outbox-demo/`, then delete it.
Only the sensor: `python3 sensor.py --sensors 3 --interval 1 --duration 5 --stdout`.

Command mode (for the later cardano-cli step): `--submit command --submit-command "./submit.sh {file} {hash}"`.
The command gets the metadata file path and the hash; exit code 0 = sent, anything else = pending and tried
again every `--retry` seconds (oldest batch first; a failing batch blocks the later ones to keep order, until
it has failed `--max-tries` times and goes to `dead/`; the number of tries is kept in the `.status` file).

**What "sent" means:** only that the submit step returned success (the node took the transaction into its
mempool). It does not mean the transaction is in a block. A crash between the submit and the status write
sends the batch again (at-least-once delivery), so the submit command must be idempotent by batch hash
(for example: do nothing if a transaction for that hash is already known). A batch in `dead/` is NOT on the
chain; somebody has to look at it.

## Not done

* MQTT between sensors and gateway: needs a broker (container) and a client library, both downloads. TCP lines are used.
* The cardano-cli call (build, sign with the gateway key, submit): only the hook exists.
* Lanes / several coins per gateway wallet: the sender submits one batch at a time.
* Reading back from the chain, the web page, the smart contract.
* Real fee, real transaction size, real `maxTxSize` of the private chain: the 1500-byte reserve is an estimate
  (contract transaction measured 1323-1325 bytes with 95 bytes of metadata).

## Open questions

1. Sensor restart (known limitation): a sensor that starts again at a lower seq is dropped as duplicate, as long as
   the old numbers are remembered (the dedup rule is unchanged). The gateway logs a warning once per sensor when a
   seq is more than 1000 below the highest seen ("sensor restarted? readings dropped as duplicates"). Keep seq across
   restarts (`--seq-start` exists), or add a boot number?
2. Duplicate memory: the last 2000 seq per sensor; older duplicates are not detected.
3. Readings waiting in memory are lost if the gateway is killed (not Ctrl-C/SIGTERM). A journal file would fix it.
   On Ctrl-C/SIGTERM a reading that arrives during the last moment is refused and counted as `late`.
4. In `dry` mode the batch is marked `sent` (so a restart does not repeat it). Fine?
5. Ids are accepted only as `[A-Za-z0-9_.-]{1,32}` not starting with 0x; rejected readings are dropped and counted.
6. Out-of-range values are sent as they are; who flags them (gateway, contract, web page)?
7. Is the timestamp the sensor's clock or the gateway's? Now: the sensor's (in the simulation, the same machine).
8. Is B=100 / T=30 s the right default for the real site rates? B is capped by the 16384 bytes only above about 1500-1800.

## Step 2: Kupo, reader, web page (12 November 2026)

Files: `kupo.sh`, `reader.py`, `server.py`, `page.html`, `gateways.json`, `test_reader.py` (25 tests, no chain needed).
The reader keeps everything in memory and rebuilds it from Kupo at start (no database of its own).

Start (on seedvm, in `~/cardano-seed-testnet/experiments/pipeline`):

```
./kupo.sh start                       # Kupo inside pool 1's container, listens on 0.0.0.0:1442, prints http://10.150.0.71:1442
./kupo.sh status                      # running? Kupo slot against the node tip
python3 server.py                     # page on 127.0.0.1:8080 (port busy? --port 8088); options: --help
```

On the Mac (the server listens on the VM's localhost only):

```
ssh -L 8080:127.0.0.1:8080 seedvm     # (use the same port you gave --port) then open http://127.0.0.1:8080/
```

`./kupo.sh wipe` deletes Kupo's database (needed after a fresh chain; `start` rebuilds it). `./kupo.sh stop` stops Kupo.
On seedvm port 8080 was already taken by another program on 12 November, so the live test used `--port 8088`.

How the page decides:
* Identity: the signer is the address of output #0 of the transaction; its name comes from `gateways.json`
  (name -> address; GW01 = gwA, GW02 = gwB). The gateway id in the metadata is only shown as "says ...".
  A different name gives "identity mismatch", an address not in the file gives "unknown signer".
* Depth in blocks: the node tip block (docker exec cardano-cli, every 2 s) at the moment a batch is first seen is its block.
  Batches already on the chain at server start (and batches found more than 30 slots after their slot) get an
  ESTIMATED depth from slots (shown as "estimate"). Final at 60 (`--final-depth`). A final batch is not asked about again.
* Rollback: every poll re-reads the last 300 slots; a batch that is not final and no longer listed is asked for again
  (/metadata); if the transaction is gone it is "rolled back" and its readings leave the sensor values; if it is in another
  block the depth starts again (shown as "moved"). Only batches below Kupo's own checkpoint are checked, so a Kupo that
  is still catching up does not look like a rollback.
* Silent: only the server clock. "Age" = seconds since a new reading for that sensor arrived from the chain (the server
  start counts as arrival for readings that were already on the chain). The age by the sensor clock is only a hint
  ("clock differs"). Default `--silent-after 90` (was 30 until 12 November; changed to 90) is a few gateway batch times
  (T = 30 s) plus the block wait; with 30 the sensors flicker to silent between batches. The demo uses the default.
* Out of range: latest value outside temperature -40..60, humidity 0..100, soil moisture 0..100 (`--limits`).
* Foreign layouts (the older map layout under label 1000) are skipped and counted, logged once.

Not done:
* Memory grows with the chain (all batches are kept in memory; the page shows the newest 100 batches).
* The exact block number of an old batch is not available from Kupo, so old batches stay estimates.
* No login, no TLS: reach it only through the ssh tunnel.
* `/api/state` is rebuilt for every request (cheap now, would need a cache with many thousands of readings).
* The node tip query starts `cardano-cli` every 2 s; a direct socket client would be lighter.
* The chart shows readings in order, not on a true time axis (sensor clocks differ and jump).
* Not tested against a real rollback on the chain (simulated only); not run for a long time.
