# joiner: one extra node joins a running network

A plain docker container, outside SEED, running the same `cardano-node` image. It joins the docker
network of pool 1's AS as `.99`, dials pool 1 at `.71:3001`, and syncs the chain. It has no pool
keys, so it never produces blocks. It carries SEED labels, so it also appears on the Internet map
(network 1's map).

```bash
./experiments/joiner/join.sh 1       # join network 1 (or: join.sh 2 for network 2)
./experiments/joiner/check.sh        # its tip next to pool 1's, plus its connection log
./experiments/joiner/join.sh stop    # remove it
```

The joiner gets the genesis files of the network it joins. Genesis files of another network
would be refused in the handshake (network magic 42 vs 43).

Run `join.sh stop` before `./run.sh` of that network: docker cannot delete a network that still
has a container attached.
