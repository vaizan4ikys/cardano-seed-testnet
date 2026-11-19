# Lab settings: the machine names and fixed values that used to be written into many scripts.
# Source it (do not run it):   source "$ROOT/scripts/config.sh"
# bash 3.2 compatible (it is also sourced on the Mac). Every value can be overridden from the environment,
# for example:  POOL_HOST=myvm ./experiments/measure/run-all.sh
#
# Our lab: a Mac drives four Ubuntu VMs over ssh (aliases in ~/.ssh/config). The network magic is NOT here:
# scripts/lib.sh derives it from NET (net 1 = magic 42, net 2 = magic 43).

# --- machines (ssh host names or aliases) ---
POOL_HOST=${POOL_HOST:-seedvm}      # the VM that runs the three stake pools (started with EXPOSE=1)
VM2=${VM2:-seedvm2}                 # extra VMs: joining nodes, relays, gateway sites
VM3=${VM3:-seedvm3}
VM4=${VM4:-seedvm4}

# --- folders ---
REPO=${REPO:-cardano-seed-testnet}  # name of this repository's folder in the home directory of every VM
P0_DIR=${P0_DIR:-/tmp/p0n}          # work folder of the contract scripts inside pool 1's container
                                    # (keys, registry, .plutus)

# --- ports ---
KUPO_PORT=${KUPO_PORT:-1442}        # Kupo (chain indexer) inside pool 1's container
PAGE_PORT=${PAGE_PORT:-8088}        # web page of the demo (127.0.0.1 on the chain host)
