# pipeline: sensors -> gateway -> chain -> Kupo -> web page

Simulated sensors (`sensor.py`) send readings to a gateway (`gateway.py`), which writes them in batches into Cardano transactions
through the gateway-registry contract (`submit_contract.sh`). `kupo.sh` runs the Kupo indexer, `reader.py` and `server.py` read the chain
back through Kupo, and `page.html` shows it. The whole thing is started and shown by [`../demo/`](../demo/README.md).

* [The layout of the data](#cardano-metadata-rules-that-shape-the-layout) a gateway writes into one transaction, and how big it is.
  Code: `layout.py` (layout, hash, size rules), `calc_size.py` (the size table below).
* [The gateway](#the-gateway-from-sent-to-final): how it keeps every batch until it is final; `check_batches.py` checks an
  outbox against the chain.
* [The web page](#the-web-page) and its server.

## Cardano metadata rules that shape the layout

* Values: integers, byte strings, text strings, lists, maps. No decimal numbers (a scaled integer is used:
  2450 with scale 100 = 24.50). No true/false/null.
* One text string: at most 64 bytes. One transaction: at most 16384 bytes (mainnet value; the spec of the private chain
  sets the same, see `../../spec/README.md`).
* `cardano-cli ... --metadata-json-file` with the default "no schema" conversion: JSON integers become
  integers, JSON strings become text, lists stay lists. (From memory: in that mode a string that starts with
  `0x` followed by hex turns into a byte string. No string of this layout looks like that.)

## Layout: lists only, grouped per sensor

```
{"1000": [1, "GW01", 17, 1760000000,
          [ ["AGRI_001", 1, 100, [[0, 2450, 5], [30, 2461, 6]]],
            ["AGRI_002", 2, 10,  [[12, 625, 3]]] ]]}
```

| level | fields |
|---|---|
| batch (value of label 1000) | `[version, gateway_id, batch_no, t0, groups]` |
| group = one sensor and one kind | `[sensor_id, kind_code, scale, readings]` |
| reading | `[dt, value, seq]` |

* `version` 1. `gateway_id` text, e.g. `GW01`. `batch_no` counts the batches of this gateway.
* `t0` = smallest unix timestamp (seconds) in the batch; the time of a reading is `t0 + dt` (integer seconds).
* `sensor_id`: the full id, e.g. `AGRI_001` (an earlier 4-character short code made `AGRI_001` and `ATMO_001`
  the same, so it was dropped).
* `kind_code`: 1 temperature (C, scale 100), 2 humidity (%, scale 10), 3 soil_moisture (%, scale 10).
  The unit is implied by the kind, so it is not stored.
* `value`: integer, may be negative. `scale`: the real value is `value / scale`.
* `seq`: sequence number of the sensor (lets the web page see gaps and duplicates).
* A sensor that reports two kinds gives two groups.
* Why lists and no maps: the node may store a map in its own key order, so the bytes of a rebuilt JSON file
  could differ from the original. With lists, order is kept and the file can be rebuilt byte for byte.

The file is written compact (`separators=(",",":")`), ASCII, no newline at the end.

### What the gateway accepts (anything else is dropped, counted, and logged once per sensor)

* Sensor id and gateway id: `^[A-Za-z0-9_.-]{1,32}$`, and not starting with `0x`/`0X` (cardano-cli would turn
  such a string into a byte string).
* Integers only (JSON true/false and decimals are refused). Cardano allows -2^64 .. 2^64-1; the gateway is
  tighter: `seq` 0 .. 2^32-1, `ts` 0 .. 2^40-1, `value` -2^53 .. 2^53 (exact in JavaScript, for the web page),
  `scale` 1 .. 10^6; `dt` is `ts - t0`, so never negative. The kind must be one of the three names.
* A rejected reading never gets into a batch; the batch is checked only through this gate.

## Batch hash rule

`batch_hash = sha256(exact bytes of the metadata JSON file of the batch)`, 32 bytes (64 hex characters in the
file name `batch-<counter>-<hash>.json`). A later smart contract takes these 32 bytes as its redeemer; the web
page reads the metadata from the chain, writes it out in the same compact form (`JSON.stringify` gives the same
bytes for lists of integers and short ASCII strings) and hashes it again. The rule needs the compact form above;
any other spacing gives another hash.

## Size (run `python3 calc_size.py`)

Test data: 10 sensors per batch (ids like `AGRI_001`), sequence numbers near 1000, 20 s of readings per batch.
"CBOR" is what goes into the transaction; the JSON file is larger (about 1.75 times) but is not what is sent.
Two transaction types: a plain payment (metadata + about 300 bytes) and a contract transaction (script witness,
redeemer, collateral, required signer, reference input: about 1230 bytes besides the metadata; measured 1323-1325
bytes in total with about 95 bytes of metadata).

```
     B |      CBOR      JSON B/reading | plain tx  contract |  old-style
     1 |        38        73      38.0 |      349      1279 |        119
    10 |       229       381      22.9 |      540      1470 |       1171
    50 |       546       937      10.9 |      857      1787 |       5853
   100 |       943      1632       9.4 |     1254      2184 |      11705
   200 |      1736      3022       8.7 |     2047      2977 |      23408
   500 |      4111      7192       8.2 |     4422      5352 |      58504
  1000 |      8067     14142       8.1 |     8378      9308 |     117010
  1500 |     12027     21092       8.0 |    12338     13268 |     175520
```

* Cost of one reading: about 8 to 9 bytes (list head 1, `dt` 1-2, `value` 3, `seq` 3), more for a long-running
  sensor (`seq` above 65535 costs 5) and for large `dt`. Per group: about 15 bytes with an 8-character id.
* Capacity under 16384 bytes (the gateway option `--tx-reserve` is the room kept for everything except the
  metadata; default 1500 = contract transaction with some room):

  | reserve | 10 sensors in the batch | 50 | 200 | old-style |
  |---|---|---|---|---|
  | 300 (plain payment) | 2011 | 1940 | 1693 | 137 |
  | 1500 (default, contract) | 1859 | 1788 | 1542 | 127 |

* More coins (inputs) in the gateway wallet cost about 40 bytes each; check the reserve if a transaction uses many.
* Old-style (the older project's sample, one map with names and unit per reading, kept as a comparison): 117 bytes
  per reading, so only about 130 readings per transaction. The earlier B=100 tests were close to that limit.
* 64-byte string limit: the longest string in this layout is the sensor id (at most 32 bytes), so it never binds.
  It would matter only if many readings were packed into one long text or byte string.
* The `maxTxSize` of the private chain is set to 16384 in `../../spec/shelley-spec.json`; the gateway splits a batch if the estimate goes above it.

## Recommended default B = 100 (and T = 30 s)

At B=100 the metadata is 943 bytes. A plain transaction is about 1.3 KB (8% of the limit), a contract transaction
about 2.2 KB (13%). Either way there is large headroom, so more sensors, a longer `seq` or more coins never break the
limit. The fixed part of a transaction (about 300 or 1230 bytes) is 3 to 12 bytes per reading at B=100 (against
9 for the reading itself), and bigger batches would save most of that: at B=500 about 0.6 to 2.5 bytes per
reading. The price of a bigger B is a longer batch-fill wait (B divided by the readings per second of the
site). B=100 is also the value of the earlier load tests, so the results stay comparable. The gateway splits a batch
automatically if the estimate ever exceeds the limit.

## The gateway: from "sent" to "final"

`gateway.py` writes the batch files and sends them (`--submit command`, normally `submit_contract.sh`). A batch is
critical sensor data, so the gateway does not stop at "the transaction was in a block once":

* **Why.** A block can be replaced by a competing block (two pools make a block for the same slot; on the lab chain about
  6 % of the forged blocks: 59 of 1,008 in 85 minutes, seen in the node logs). Cardano does **not** put the transactions of a replaced block back into the mempool.
  The submit command returns 0 as soon as the transaction is in a block, so without more care the batch (about 100
  readings) would be lost and nobody would notice.
* **What the gateway does** (needs `--kupo URL`; `demo.sh` passes it). It keeps the transaction id of every submitted batch
  (the last 64-hex word of the last line the submit command prints on stdout; notes on stderr are ignored), writes it into `batch-....json.tx` and sets the
  status to **settling**. Every `--confirm-interval` seconds (15) it asks Kupo about each settling batch:
  in a block: how many blocks are on top; at `--final-blocks` (60 = k) the status becomes **final**.
  Not listed by Kupo for longer than `--missing-grace` seconds (60; Kupo is normally less than a second behind the node):
  the block was replaced. The gateway logs `batch X: its transaction is no longer in the chain (block replaced): sending it
  again` and sets the batch back to **pending** (its `.tx` file stays). The checking never submits anything, so it cannot
  hold up new batches (a resend takes 10 to 100 seconds). The sender thread submits the **same file** again (same hash)
  like any other pending batch, **oldest first** (each batch spends the coin of the one before); `p1-batch.sh` sees that
  the old transaction is neither in the chain nor in the mempool and builds a new one. The sender counts failed tries like
  for a first submit (`--max-tries`). A resend that the contract refuses for good (exit 2, for example the gateway was
  revoked meanwhile) goes to `dead/`. Before a batch that was in the chain once goes to `dead/` after too many failed tries,
  the gateway asks Kupo for its last transaction; if that is in the chain after all, the batch is followed again.
* **Final never too early.** The block of a transaction is the tip block when it was first seen. If the gateway sees it
  late (after a restart, or Kupo was behind), the gateway stores the tip block of that moment, which is never older than
  the real block: "final" can only come late, never early. If the tip is too old to trust, it waits for the next round.
* **Same method as the page.** Kupo gives the slot of the transaction (`/matches/*@<txid>`), the node gives the tip block
  (`reader.DockerTip`), and the block of a transaction is the tip block when it was first seen (`reader.first_seen_block`;
  when it was seen late, `confirm.py` takes the tip block, see below). Depth = tip block - block + 1, like "Settling n/60" on the page.
* **Kupo must keep spent outputs.** The change output of a batch transaction is spent by the next batch, so a Kupo that
  pruned spent outputs would make old batches look missing. `kupo.sh` starts Kupo with `--match '*'` and without
  `--prune-utxo`, so they stay (the page and `p1-batch.sh` rely on the same). As a safety net the gateway asks for the
  metadata of the slot where it saw the transaction before (Kupo keeps it) and logs a warning if that works while the outputs are missing.
* **No false alarm when Kupo or the node is the problem.** If Kupo does not answer, is not connected to the node, is more than
  30 slots behind, or the tip cannot be read, the round is skipped and logged once; nothing is concluded from it.
* **Status files** (next to `batch-NNNNNN-<hash>.json`):

  | `.status` | meaning |
  |---|---|
  | `pending` / `pending <n>` | not sent yet / failed n times (after `--max-tries` it goes to `dead/`) |
  | `settling` | submitted; the transaction is in the `.tx` file; followed until final |
  | `final` | final, nothing more to do |
  | `sent` | submitted but not followed: dry mode, no `--kupo`, no transaction id in the output, or an outbox of the old gateway |

  The `.tx` file is JSON: `txid`, `slot`, `header` (block header hash), `block` (tip block when first seen) and `resends`
  (how often the batch was sent again). A restart keeps all of this: the settling batches are followed on.
* **Log lines:** `sent: FILE (transaction ...)`, `final: FILE (transaction ..., 60 blocks deep)`, `batch X: its transaction is no
  longer in the chain (block replaced): sending it again`, `sent again: FILE (new transaction ..., resend 1)` (only `sent: ` lines are new batches).
* **Options:** `--kupo URL` (default `$KUPO_URL`; without it nothing is followed and a warning is logged), `--final-blocks 60`,
  `--confirm-interval 15`, `--missing-grace 60`, `--container` and `--magic` (for the node tip, as in `server.py`).

### Did every batch reach the chain? `check_batches.py`

```
python3 check_batches.py --outbox /tmp/demo-run-XXXX/outboxA --kupo http://10.150.0.71:1442 [--gateway-id GW01] [--list]
```

Counts the batch files of an outbox: **final**, **settling** (in the chain, fewer than 60 blocks on top), **pending**
(never sent), **dead** and **LOST** (the gateway says sent, but the batch is not in the chain), with the number of readings
of each group. Exit code 1 if something is LOST. It also works on an outbox of the **old** gateway, which stored no transaction
id: a batch is found on the chain by its transaction id (new gateway), else by its hash (it is in the file name), else by
content: every reading (gateway id, sensor id, sequence number) of the file is in some batch on the chain. The depth is
the gateway's own record when there is one, else the page's estimate from the node tip and the slots (the node tip comes from `docker exec`;
without docker, from Kupo's slot, then settling/final is only approximate).

Tests: `python3 -m unittest -v` in this folder (`test_confirm.py` covers the following of batches and the checker with a fake Kupo, tip and submit step).

## The web page

`server.py` serves `page.html` and the data as JSON. It keeps everything in memory and rebuilds it from Kupo at start (no database of its own).
A reader thread asks Kupo for new batches about every 2 s; a second thread asks the node for its tip every 2 s; a third reads the registry every 3 s.

```
python3 server.py --port 8088 --kupo http://<pool-1 container ip>:1442     # page on 127.0.0.1:8088; all options: --help
```

The server listens on `127.0.0.1` only (no login, no TLS): reach it from another machine through an ssh tunnel
(`ssh -L 8088:127.0.0.1:8088 <user>@<vm>`), then open <http://127.0.0.1:8088>. `GET /api/state` gives the data, `GET /health` a short status.
In normal use `../demo/demo.sh` starts it with the right options.

The page has a header and three big view buttons, **Sensors**, **Trust** and **Details**; a button switches what is shown under the header:

* **Header:** *Sensors live* (sensors that are not silent, out of all seen), *Readings stored permanently* (readings in batches that are final), *Approved gateways*
  (named gateways that are on the registry list, out of the named gateways), and the connection to the chain with the tip block.
* **Sensors (button):** one card per sensor and kind, grouped by gateway; the gateway has an Approved / Not approved badge. A card shows the latest value, a small curve and
  **Live**, **Silent** or **Out of range**. Click a card for a graph with lowest, average and highest value and the value under the mouse.
* **Trust (button):** *Who may send data?* is a table of the gateways with Approved / Not approved, batches and readings stored, time of the last data.
  *Is the stored data safe?* counts batches that are final, settling (in a block, fewer than `--final-depth` blocks on top) and rolled back, and lists the latest batches.
  The **Verify** button of a batch shows the transaction id, the block and depth, the fingerprint of the data (the batch hash from above), the signer and what this proves.
* **Details (button):** chain tip, Kupo status, server time, counts, size of the registry list; technical tables of the latest batches (depth bars, warnings such as "identity mismatch") and of the gateways (addresses, receipts).

**Approved or not is read from the chain.** The registry (the list of approved gateway keys) is one coin at the administrator address that holds the registry token, with the list as its inline datum.
The server finds that coin through Kupo (`/matches/<admin address>?unspent`, then `/datums/<hash>`), turns the list into key hashes and compares them with the key hash of each
gateway's wallet address (`reader.Registry`). So the page shows a revoke or an enrol a few seconds after the transaction is in a block. If the list cannot be read, the badge says
"list unknown" and the Trust view shows the error.

The server option `--registry-dir DIR` (default `/tmp/p0n`) is the directory **inside pool 1's container** with `admin.addr`, `policy.id` and `token.hex`
(they are written by `../contract/in-container/p0-admin.sh` and `p0-registry.sh`; the server reads them with `docker exec`). `--registry-dir none` switches the registry reading off:
all badges then say "list unknown". Other options that matter: `--final-depth` (blocks until final, default 60), `--silent-after` (seconds until a sensor is silent, default 90; the demo uses 40),
`--limits` (out-of-range limits), `--gateways-file` (name to wallet address, default `gateways.json`), `--container`, `--magic`, `--receipt-policy`.
