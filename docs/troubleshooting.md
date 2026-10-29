# Troubleshooting

**The chain stopped and never recovers.**
If all nodes are frozen for more than 3k/f = 900 s (laptop lid closed, VM suspended), the nodes log
"Too far from the chain tip". Start a new chain with `./run.sh`. On a Mac host, keep it awake with
`caffeinate -dims`.

**The chain never starts.**
The first block must come within 900 s of the genesis start time. If generating the genesis and
starting the containers were further apart, run `./run.sh` again.

**`DeadlineExceeded` while building images.**
Build with fewer parallel jobs: `COMPOSE_PARALLEL_LIMIT=2 ./run.sh`.

**The Internet map shows no BGP peers for a router (but `birdc show protocols` does).**
The map's controller can get stuck (seen right after start-up, possibly also after an extra node
joins). It is a SEED map problem, not a Cardano one. Restart the map and reload the page:
`docker restart seedemu_internet_map`.

**`docker compose down` in `build/net-<N>/output` finds nothing.**
The compose project is named `cardano-net-<N>`, not `output`. Use `./stop.sh` (with `NET=<N>`).

**`cardano-node` refuses the pool keys.**
Key files must not be readable by group or others (`chmod 600`).

**A new transaction fails with "All inputs are spent".**
The previous transaction was not in a block yet. `send-metadata.sh` and `test-tx.sh` wait for the
block; if you submit by hand, wait until the transaction's output exists on the ledger.
