# pipeline (phase 1: sensors -> gateway)

The layout of the data that a gateway writes into one Cardano transaction, and how big it is.
Code: `layout.py` (layout, hash, size rules), `calc_size.py` (the size table below). Not yet run on the chain.

## Cardano metadata rules that shape the layout

* Values: integers, byte strings, text strings, lists, maps. No decimal numbers (a scaled integer is used:
  2450 with scale 100 = 24.50). No true/false/null.
* One text string: at most 64 bytes. One transaction: at most 16384 bytes (mainnet value; the private chain may
  have another `maxTxSize`, not checked).
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
* The real `maxTxSize` of the private chain was not checked.

## Recommended default B = 100 (and T = 30 s)

At B=100 the metadata is 943 bytes. A plain transaction is about 1.3 KB (8% of the limit), a contract transaction
about 2.2 KB (13%). Either way there is large headroom, so more sensors, a longer `seq` or more coins never break the
limit. The fixed part of a transaction (about 300 or 1230 bytes) is 3 to 12 bytes per reading at B=100 (against
9 for the reading itself), and bigger batches would save most of that: at B=500 about 0.6 to 2.5 bytes per
reading. The price of a bigger B is a longer batch-fill wait (B divided by the readings per second of the
site). B=100 is also the value of the earlier load tests, so the results stay comparable. The gateway splits a batch
automatically if the estimate ever exceeds the limit.
