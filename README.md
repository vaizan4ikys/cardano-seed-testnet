# Cardano private testnet in the SEED Emulator

A private Cardano blockchain with 3 stake pools, running inside the
[SEED Internet Emulator](https://github.com/seed-labs/seed-emulator). Every pool sits in its own
autonomous system and talks to the others over the emulated Internet (BGP/OSPF routers).

Part of the CyberTel project *Decentralized Sensor Data Management for Critical Applications
Using Blockchain Technology*: Cardano replaces Ethereum as the ledger.

## Start here

* **Install and run the demo on your own Ubuntu virtual machine** (on a Windows PC or a Mac): [`docs/INSTALL.md`](docs/INSTALL.md).
  Step by step, from "nothing installed" to the demo in your browser.
* **Run and present the demo** (sensors, gateway, smart contract, chain, web page): [`experiments/demo/README.md`](experiments/demo/README.md).

The rest of this file is about the chain itself.

## Requirements

* Linux machine or VM (Ubuntu 22.04 recommended, amd64 or arm64; 20.04 also works; **not 24.04**: its Python 3.12 is too new for SEED's pinned packages) with at least 2 CPUs, 4 GB RAM and 30 GB disk (10 GB free)
* Docker Engine with the Compose v2 plugin (Ubuntu packages `docker.io` and `docker-compose-v2`), usable without `sudo`
* an NTP-synced clock (`timedatectl` shows `System clock synchronized: yes`; the chain takes its time from it)
* `git`, `python3`, `python3-venv`, `python3-dev`, `build-essential`, `curl`, `jq`, `openssl`, `rsync`
* [seed-emulator](https://github.com/seed-labs/seed-emulator) cloned into `~/seed-emulator` and at its release v1.1 (`git clone --branch v1.1 ...`, commit `e26637e`, the tested one); its Python packages
  go into a virtual environment `~/seed-venv` (`./install.sh` creates it; `run.sh` finds seed-emulator and that environment by itself)
* for the demo also Aiken v1.1.24 and Kupo v2.12.0 (`./install.sh` downloads them into `~/tools`)
  (the full step-by-step guide is [`docs/INSTALL.md`](docs/INSTALL.md))
* optional: [`age`](https://github.com/FiloSottile/age) for encrypted messages

`./install.sh` installs all of this (it shows the few commands that need `sudo` and asks before running them);
`./install.sh --check` only checks and prints PASS or FAIL for each item.

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
`EXPOSE=1 ./run.sh` also makes pool 1 reachable from other machines (see `experiments/join-node`).

## Where to look

| Folder | Content |
|---|---|
| [`scripts/`](scripts/) | check the chain, send transactions and messages, leadership, partition test |
| [`experiments/`](experiments/) | extra nodes joining a running network, measurements, load tests (list in its README) |
| [`experiments/demo/`](experiments/demo/) | the leader demo: `fresh.sh` (new chain + contract + registry), `demo.sh` (`--prepare` before the talk, `--show` in the talk, `--step 6` after; no option = rehearsal); presenter's guide |
| [`experiments/pipeline/`](experiments/pipeline/) | simulated sensors, gateway, Kupo indexer script, page server and the web page (Sensors / Trust / Details) |
| [`experiments/contract/`](experiments/contract/) | the gateway-registry smart contract (Aiken, Plutus V3), the scripts that deploy and test it, and the measured cost of it (`PHASE3-RESULTS.md`) |
| [`experiments/multisite/`](experiments/multisite/) | real gateways at three sites (three more VMs), each with its own node, wallet and sensors, sending through the contract; needs three extra machines, not part of the demo |
| [`spec/`](spec/) | chain parameters (slot length, epoch, k, f) |
| [`image/`](image/) | the docker image |
| [`docs/`](docs/) | [`INSTALL.md`](docs/INSTALL.md) (install and run on your own VM), [`troubleshooting.md`](docs/troubleshooting.md) (known problems and fixes) |

`cardano.py` is the SEED script (topology, pools, start commands) and `build/` holds everything
generated (keys, genesis, compose files; git-ignored).

## License

GPL-3.0, like the SEED Emulator it builds on. See [LICENSE](LICENSE).
