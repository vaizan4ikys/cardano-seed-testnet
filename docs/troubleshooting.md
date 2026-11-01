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

**`sudo` takes 15 seconds on a cloned virtual machine.**
After `hostnamectl set-hostname <new>` the line `127.0.1.1 <old name>` in `/etc/hosts` is still
there, and `sudo` waits for a lookup of the new name to time out. Make the line match:
`sudo sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $(hostname)/" /etc/hosts`.

## Pool 1 stops hearing from the other pools (chain splits, pool 1 forges alone)

**Symptom:** after hours with `EXPOSE=1`, pool 1's tip differs from pools 2 and 3 and never converges; pools 2 and 3 cannot open
TCP connections to `10.150.0.71:3001` (a `/dev/tcp` test from their containers fails), while pool 1 can reach them and `ping` works.
`conntrack -L -p tcp --dport 3001` shows many `SYN_SENT [UNREPLIED]` entries with mismatching NAT addresses.

**Cause:** the `EXPOSE=1` rule was `MASQUERADE` for all TCP to pool 1's port 3001, which also rewrote the other pools' own traffic.

**Fix:** `expose_rule` in `scripts/lib.sh` now masquerades only traffic from outside 10.0.0.0/8. On a running network:
`sudo iptables -t nat -D POSTROUTING -p tcp -d 10.150.0.71 --dport 3001 -j MASQUERADE`, then `expose_rule add` (new rule),
then `sudo conntrack -D -d 10.150.0.71`. The pools reconnect and the shorter chain is replaced by the longer one.
