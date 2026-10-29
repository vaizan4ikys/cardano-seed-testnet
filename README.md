# Cardano private testnet in the SEED Emulator

A private Cardano blockchain with 3 stake pools, running inside the
[SEED Internet Emulator](https://github.com/seed-labs/seed-emulator). Every pool sits in its own
autonomous system and talks to the others over the emulated Internet (BGP/OSPF routers).

Part of the CyberTel project *Decentralized Sensor Data Management for Critical Applications
Using Blockchain Technology*: Cardano replaces Ethereum as the ledger.

## Requirements

* Linux machine or VM with Docker (+ Compose plugin) and an NTP-synced clock
* [seed-emulator](https://github.com/seed-labs/seed-emulator) cloned, `export PYTHONPATH=$HOME/seed-emulator`
* Python 3 and `openssl` (optional: [`age`](https://github.com/FiloSottile/age) for encrypted messages)

## Quick start

```bash
./run.sh                  # first time: builds the image; then new genesis, 3 pools up
./scripts/check.sh        # all pools should show the same chain tip
./scripts/test-tx.sh      # send 1000 ADA between the two funded addresses
./stop.sh                 # remove the containers
```

The first start takes a few minutes. **Every `./run.sh` creates a new chain.**
The Internet map is at `http://<machine-ip>:8080/`.

A second, independent network (magic 43) runs next to the first: `NET=2 ./run.sh`,
`NET=2 ./stop.sh`. Every script accepts the same `NET=` prefix.

## Where to look

| Folder | Content |
|---|---|
| [`scripts/`](scripts/) | check the chain, send transactions and messages, leadership, partition test |
| [`experiments/`](experiments/) | extra nodes joining a running network |
| [`spec/`](spec/) | chain parameters (slot length, epoch, k, f) |
| [`image/`](image/) | the docker image |
| [`docs/`](docs/troubleshooting.md) | known problems and fixes |

`cardano.py` is the SEED script (topology, pools, start commands) and `build/` holds everything
generated (keys, genesis, compose files; git-ignored).

## License

GPL-3.0, like the SEED Emulator it builds on. See [LICENSE](LICENSE).
