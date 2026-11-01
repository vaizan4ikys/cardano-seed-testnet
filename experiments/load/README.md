# load: keep the blocks of the chain full

The measurements in `../measure` are more realistic on a chain that carries data. With nothing to
include, every block is empty (about 1 KB); a sensor system fills them. This keeps the mempool
supplied with ~15 KB metadata transactions, so that almost every block the pools forge is full
(the limit is 64 KB, and 4 of these transactions fit in it). The chain then also grows: about
45 MB per hour at 12 blocks per minute.

```bash
./experiments/load/load.sh dry-run    # build and sign a few transactions, print their size, submit nothing
./experiments/load/load.sh start      # start in the background, inside pool 1's container
./experiments/load/load.sh status     # transactions sent, mempool, database size, last log lines
./experiments/load/load.sh stop
```

Run it on the machine that hosts the network. How it works:

* It spends **utxo2** only. `send-metadata.sh` and the measurements spend utxo1, so they do not
  collide with it.
* The first time it splits the funds of utxo2 into 16 "lanes" (UTxOs). Each transaction spends one
  lane and returns the rest to the same address, so there is one transaction per lane per block.
* Every second it looks at the mempool and adds transactions until `FILL_TXS` (5) are waiting. The
  mempool holds about 8, so a measurement transaction still fits in.
* It pauses when no new block has come for `STALL_SECONDS` (120), and stops when the chain
  database reaches `MAX_DB_MB` (2000) or when you run `stop`.
* It works in its own folder `/tmp/load` inside the container. The measurements build transactions in
  `/tmp` of the same container; with shared file names (`meta.json`, `tx.signed`) the two would
  overwrite each other's files and submit each other's transactions.
* The transactions carry metadata label **9999**, so they are easy to tell from real messages (674).

The settings `LANES`, `STRINGS` (64-byte strings per transaction, 230 gives ~15 KB), `FILL_TXS`,
`MAX_DB_MB` and `STALL_SECONDS` are environment variables of `load.sh start`.
A fee is ~16 000 lovelace per transaction, so the funds of utxo2 last for millions of them.
