# join-node: one extra node joins a running network

A plain docker container, outside SEED, running the same `cardano-node` image. It has no pool keys,
so it never produces blocks: it dials one pool, syncs the chain and follows it. It starts with an
empty database every time, so you can time the sync.

| | `local` | `remote` |
|---|---|---|
| Runs on | the machine that hosts the network | another machine |
| Reaches the pool through | the docker network of pool 1's AS (`.99`, dials `.71:3001`) | the host's published port, over the real network |
| Chain files | copied from `build/net-<N>/testnet` | `fetch-chain-files.sh` copies them over SSH |
| On the Internet map | yes (SEED labels) | no |
| Host needs | nothing | `EXPOSE=1 ./run.sh` |

## Local

```bash
./experiments/join-node/join.sh local 1       # network 1 (or: local 2)
./experiments/join-node/check.sh              # its tip next to pool 1's, plus its connection log
./experiments/join-node/join.sh stop          # before ./run.sh of that network
```

## Remote

Machine A hosts the network, machine B runs the extra node.

```
machine A: SEED net-1, pool 1 published on port 3001  <----  machine B: node dials A:3001, syncs
```

**On A:**

```bash
EXPOSE=1 ./run.sh          # publishes pool 1 on port 3001 (network 2: 3002)
```

`EXPOSE=1` also adds one `iptables` rule (needs `sudo`). Docker forwards the remote packets into the
SEED network, but the pool answers through its SEED router, which cannot reach the outside, so the
answer would be lost. The rule rewrites the source address so that the pool answers through the
docker bridge. `./stop.sh` removes it again.

**On B** (this repo cloned and the image `seedemu-cardano:local` present):

```bash
./experiments/join-node/fetch-chain-files.sh seed@<A-ip>   # config + genesis, no keys
./experiments/join-node/join.sh remote <A-ip>              # (network 2: add the port 3002)
./experiments/join-node/check.sh seed@<A-ip>               # its tip next to pool 1's on A
./experiments/join-node/join.sh stop
```

`fetch-chain-files.sh` uses SSH to A; if B has no key for A, log in to B with `ssh -A` to borrow the
key of your own machine.

Requirements for remote mode:
* B reaches A on TCP port 3001 (`nc -zv <A-ip> 3001`), no firewall in the way
* the same `cardano-node` version on both (the same image; build it from `image/` or copy it with
  `docker save seedemu-cardano:local | gzip | ssh B 'gunzip | docker load'`)
* clocks of both machines synchronised (NTP)

## Wrong genesis

A node with the genesis of another network (other magic) is refused in the handshake
(`version data mismatch ... NetworkMagic 42 /= 43`). To see it, copy the other network's
`config.json` and `*-genesis.json` into `build/joiner/` before starting the node.
