# scripts

Run them from the repo root, e.g. `./scripts/check.sh`. They all use the network chosen with
`NET=` (default 1, e.g. `NET=2 ./scripts/check.sh`); the shared settings are in `lib.sh`.

| Script | What it does |
|---|---|
| `gen-testnet.sh` | genesis, pool keys and the two funded addresses into `build/net-<N>/testnet/` (called by `run.sh`) |
| `check.sh` | chain tip of each pool; they should agree |
| `test-tx.sh` | sends 1000 ADA from `utxo1` to `utxo2` through pool 1 and shows it on every pool |
| `send-metadata.sh` | writes a text message into a transaction's metadata |
| `read-metadata.sh` | reads such a message back, decrypting it if needed |
| `leadership.sh [pool] [current\|next]` | slots a pool will lead (its VRF lottery wins) |
| `partition-test.sh` | cuts pool 3 off for a while, shows the fork and how it heals |

## Messages on the chain

```bash
./scripts/send-metadata.sh -m "temp-01: 21.4"            # plain text
./scripts/send-metadata.sh -k "secret" -m "temp-01: 21.4" # encrypted with a shared password
./scripts/send-metadata.sh -R readers.txt -m "..."        # encrypted for age public keys

./scripts/read-metadata.sh <txid>                         # the txid is printed by send-metadata.sh
./scripts/read-metadata.sh <txid> -k "secret"
./scripts/read-metadata.sh <txid> -i my-age-key.txt
```

* The message goes into metadata label 674. Cardano allows 64 bytes per string, so longer text is
  split automatically. A whole transaction is limited to 16 KB.
* Encryption happens on the host. The container and the chain only see the encrypted text.
* Every message is also saved in `build/net-<N>/sent/<txid>.json`.
* The transaction is paid by `utxo1`; the change returns to `utxo1`.
* `age` must be installed for `-r` / `-R`; `-k` only needs `openssl`.

## Partition test

`CUT_SECONDS=120 ./scripts/partition-test.sh` stops pool 3's router for 120 s. Keep it under about
400 s: with k = 60 an isolated pool that forges more than 60 blocks cannot roll back.
