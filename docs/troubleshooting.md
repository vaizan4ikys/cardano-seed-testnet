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

**A transaction was submitted but never shows up in a block; `fresh.sh` stops with "STOP: p0-registry.sh failed" (registry transaction not seen).**
**Cause:** the transaction was in a block for a moment, and the block was dropped. Two pools forged a block in the same slot, the node
that had sent the transaction into its own block lost the tie and switched to the other block ("Switched to a fork" in the node log),
and Cardano does not put the transactions of a dropped block back into the waiting room. On our chain this happens to about 6 % of the
forged blocks (59 of 1,008 in one 85-minute log; see `./scripts/fork-stats.sh` and [FAQ, question 11](FAQ.md#11-why-can-a-transaction-disappear-after-it-was-in-a-block)).
It is not a bug in the scripts or the contract.
**Fix:** run the failed step again; the new chain, the keys and the contract build are kept, so no rebuild is needed:
`./experiments/demo/fresh.sh --from 7 --yes` (step 7 mints the registry token; use the number of the step that failed).
Since 20 November 2026 the scripts check every 10 s while they wait and send the same transaction again if it is neither in a
block nor in the mempool; the registry and funding steps
also wait for one more block on top, and the gateway keeps every batch until it is final (60 blocks), so a single dropped block
should no longer stop anything.
To see whether blocks were dropped around the time of the failure: `./scripts/fork-stats.sh --since "<date and time>" --list`.

**The gateway log shows `submit command exit 1: ... BadInputsUTxO ...` and `not sent: ... (try 1 of 5)` right after a registry change.**
Every batch transaction reads the registry coin. While the administrator's registry change waits in the mempool, the node refuses
every new transaction that reads the old registry coin, so the gateway's batch fails until the change is in a block (seen in the
demo on 20 November 2026: one or two failed tries at each change, then the batch went through; nothing was lost). Since then
`p1-batch.sh` waits for the next block itself (at most 2 x 20 s) and builds again, and the gateway log shows `note from the submit
command ...: ... waiting for the next block` instead. Before, a block slower than about 25 s could use up the gateway's 5 tries and move a
good batch to `dead/`.

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

## Pools do not connect to each other, blocks come slowly (one VM, 19 November 2026)

**Symptom:** the chain makes a block only every 10-15 s instead of about 5 s; the three pools show different tip hashes
(`./scripts/check.sh`); in the router of AS150 `birdc show protocols` shows a BGP session "Active ... Connection reset by peer";
the demo fails at step 5 or 6 because batches wait too long.
**Cause** (found later the same day on a new VM, reproduced with 30 small test images): SEED writes all files within one
clock tick, so files of different nodes have the same name, size and modification time. The legacy builder that
`docker compose` uses when the buildx plugin is missing (Ubuntu's `docker.io` package) then puts one node's file into
another node's image (for example router r100 got the BGP config of r102), even with `--no-cache`; later runs reuse
those images.
**Fix (automatic since then):** `run.sh` gives every service folder its own file time before building
(`scripts/check-images.sh --stamp`; test: 28 of 30 images wrong before, 0 of 30 after), and after `docker compose up` it
runs `scripts/check-images.sh`, which compares the files in every container with the generated ones and rebuilds wrong
images (with new file times). By hand:
`./scripts/check-images.sh --check` (compare only) or `./scripts/check-images.sh` (compare and repair).
