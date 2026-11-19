#!/bin/bash
# Real gateways at up to three sites, each with its own node, its own wallet and its own sensors, sending through the
# registry contract. Runs on the Mac (drives the VMs over ssh) or on the chain VM itself. bash 3.2 compatible.
# The chain (EXPOSE=1) and Kupo must run on the chain host, the load must be off.
#
# Two ways to place the sites (switch SITES):
#   SITES=vms    the classic way: site k runs on its own machine seedvm2/seedvm3/seedvm4 (VM2..VM4 in scripts/config.sh),
#                the chain on seedvm. Default when run from the Mac.
#   SITES=local  everything on ONE machine (the chain host): the site nodes are extra containers site1..site3 next to the
#                chain, the gateways and sensors are processes on that same machine (ports 9111..9113). Default when this
#                script runs on Linux, that is on the chain VM itself. From the Mac it also works:
#                SITES=local ./multisite.sh ... (drives seedvm over ssh).
# Where the chain host is comes from CHAIN_HOST as in ../demo/host.sh (local on Linux, seedvm on the Mac).
# SITES_COUNT=1..3 (default 3) uses only the first sites: each site node needs RAM (see "mem"); a 4 GB machine fits 2-3.
#
# Other settings (environment):
#   EXU="(steps,memory)"  execution units the gateways declare (default "(40600000,132100)": enough for 10 keys on the list)
#   MAXTRIES=5            failed submits before a batch goes to dead/ (the gateway default)
#   MINFREE=500           MB of available RAM that must be left before a site node is started (SITES=local)
#
#   ./multisite.sh setup            nodes + wallets + funding + enrolment of the site gateways (about 10 min)
#   ./multisite.sh start [N]        gateways + N sensors each (default 10, 1 reading/s each) at the sites
#   ./multisite.sh stop             stops gateways and sensors (the outboxes stay)
#   ./multisite.sh status           per site: batches sent / pending / dead, last log line
#   ./multisite.sh mem              free RAM of the machine and RAM used by each site node
#   ./multisite.sh cut SITE|uncut SITE   (SITE = 1..3) 100 % packet loss on the site's node
#   MAXTRIES=1000 ./multisite.sh gwrestart K   restart the gateway of site K on the same outbox
#                                   (patient: no dead letters for network trouble)
#   ./multisite.sh enrol N | revoke N    registry: enrol/revoke site gateway N (1..3)
#   ./multisite.sh sensors N        restart the sensors of all sites with N sensors each (the gateways keep running)
#   ./multisite.sh backlog          one line: pending batches at each site
#   ./multisite.sh teardown         revoke all sites, remove the nodes, delete the site keys (the wallets' coins stay on the chain)
#
# Site k (1..3): node container site$k, gateway G$((k+2)) = name GW0$((k+2)), sensors AGRI_${k}01.. (SITES=vms: machine seedvm2/3/4).
# The key of each gateway is made inside its own container and never leaves it.
# SITES=local needs sudo for "cut" (tc in the container's network namespace) and docker for the user.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
. "$ROOT/scripts/config.sh"     # POOL_HOST, VM2..VM4, REPO, P0_DIR (lab settings)

# ======================================================================================================
# Settings
# ======================================================================================================
MAGIC=42                                                    # network magic of net 1
VMS=("$VM2" "$VM3" "$VM4")                                  # the machines of sites 1..3 (SITES=vms)
EXU=${EXU:-"(40600000,132100)"}
MAXTRIES=${MAXTRIES:-5}                                     # failed submits before a batch goes to dead/ (the gateway default)
N=${SITES_COUNT:-3}                                         # how many sites
case "$N" in 1|2|3) ;; *) echo "SITES_COUNT must be 1, 2 or 3"; exit 1;; esac
MINFREE=${MINFREE:-500}                                     # MB of available RAM that must be left before a site node is started
STATE=$HERE/state; mkdir -p "$STATE"                        # addresses (public) of the site gateways
SENSORS_DEFAULT=10                                          # sensors per site for "start"
SCRIPTS_IN_CTR=/tmp/p0-scripts                              # where the contract scripts are inside the containers

# ---- where is the chain host (the same helper as the demo) and where are the sites ----
SSHO="-o ConnectTimeout=10 -o ServerAliveInterval=15"
SSHO="$SSHO -o ControlMaster=auto -o ControlPath=/tmp/ms-cm-%C -o ControlPersist=120"
. "$HERE/../demo/host.sh"       # CHAIN_HOST, LOCAL, vm(), push(): LOCAL=1 when this script runs on the chain host itself
if [ -z "${SITES:-}" ]; then
  if [ $LOCAL = 1 ]; then SITES=local; else SITES=vms; fi
fi
case "$SITES" in local|vms) ;; *) echo "SITES must be local or vms"; exit 1;; esac
if [ $SITES = local ]; then
  POOL=$CHAIN_HOST
  if [ $LOCAL = 1 ] && ! local_repo_ok "$ROOT"; then
    echo "SITES=local on the VM: the repository must be in \$HOME/$REPO"; exit 1
  fi
else
  # the chain host is reached over ssh in this mode
  if [ $CHAIN_HOST = local ]; then POOL=$POOL_HOST; else POOL=$CHAIN_HOST; fi
fi

# ======================================================================================================
# Helpers. They differ for the two ways to place the sites:
#   on HOST CMD      run CMD in the repository on HOST          vm_of K   the machine of site K
#   gport K          the port the sensors of site K send to      gwn K / sn K   process names for demo/remote.sh
#   obx K RUNDIR     the outbox folder of site K
# ======================================================================================================
if [ $SITES = local ]; then
  # one machine: "on HOST cmd" ignores HOST and runs cmd in the repository on the chain host (host.sh: this machine or ssh)
  on() { shift; vm "cd $REPO && $*"; }
  vm_of() { echo "$POOL"; }
  gport() { echo $(( 9110 + $1 )); }                       # 9101/9102 belong to the demo gateways A and B
  gwn() { echo "gwS$1"; }                                  # process names for demo/remote.sh (one pair per site)
  sn() { echo "sensorsS$1"; }
  obx() { echo "$2/outbox$1"; }                            # obx SITE RUNDIR
else
  on() { local vm=$1; shift; ssh -A -o BatchMode=yes "$vm" "cd $REPO && $*" 2> >(grep -v -e '^\*\*' >&2); }
  ip_of() { ssh -o BatchMode=yes "$1" hostname -I 2>/dev/null | cut -d' ' -f1; }
  vm_of() { echo "${VMS[$(( $1 - 1 ))]}"; }
  gport() { echo 9100; }
  gwn() { echo gw; }
  sn() { echo sensors; }
  obx() { echo "$2/outbox"; }
fi
sites() { seq 1 "$N"; }
gid() { echo "G$(( $1 + 2 ))"; }
gname() { echo "GW0$(( $1 + 2 ))"; }
# pool CMD...: run a command inside pool 1's container (as the administrator's work folder)
pool() { on "$POOL" "source scripts/lib.sh && docker exec -e P0_DIR=$P0_DIR \$(require_pool 1) $*"; }
# the repository as an absolute path on the site machines (the gateway processes need it)
HOME_REPO=/home/seed/$REPO
init_home() { [ $SITES = local ] && HOME_REPO=$(vm 'echo $HOME' | tail -1)/$REPO; return 0; }
free_mb() { on "$POOL" "awk '/MemAvailable/ {print int(\$2 / 1024)}' /proc/meminfo" | tail -1; }

# ======================================================================================================
# setup: nodes, wallets, funding, enrolment of the site gateways
# ======================================================================================================
setup() {
  [ "$(on "$POOL" './experiments/load/load.sh status' | head -1)" = running ] \
    && { echo "the load is running: stop it first"; exit 1; }
  local POOL_IP k vmx g pkh
  if [ $SITES = local ]; then
    on "$POOL" "source scripts/lib.sh && docker port \$(require_pool 1) 3001" >/dev/null 2>&1 \
      || { echo "pool 1 does not publish port 3001: start the chain with EXPOSE=1 ./run.sh"; exit 1; }
    # the site containers dial pool 1 through the docker bridge of this machine (the published port 3001)
    POOL_IP=$(on "$POOL" "docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}'" | tail -1)
    push "$ROOT/experiments/" "$REPO/experiments/" --exclude results --exclude state
    # public chain files for the site nodes (no keys): what fetch-chain-files.sh would copy over ssh
    on "$POOL" "mkdir -p build/joiner && cd build/net-1/testnet && cp config.json *-genesis.json ../../joiner/"
    for k in $(sites); do on "$POOL" "docker rm -f site$k >/dev/null 2>&1; true" >/dev/null; done
  else
    POOL_IP=$(ip_of "$POOL")
    for vmx in "${VMS[@]}" "$POOL"; do
      rsync -a --exclude results --exclude state "$ROOT/experiments/" "${vmx}:$REPO/experiments/" \
        2> >(grep -v -e '^\*\*' >&2)
      [ "$vmx" = "$POOL" ] && continue
      on "$vmx" "./experiments/join-node/fetch-chain-files.sh seed@$POOL_IP" >/dev/null
      on "$vmx" 'docker rm -f $(docker ps -aq --filter name=site) >/dev/null 2>&1; true' >/dev/null
    done
  fi
  on "$POOL" "docker cp experiments/contract/in-container/. \$(source scripts/lib.sh; pool_container 1):$SCRIPTS_IN_CTR/" \
    >/dev/null

  echo "1. nodes (each one syncs from pool 1)"
  for k in $(sites); do
    if [ $SITES = local ]; then   # RAM guard: one more node must leave MINFREE MB
      local f; f=$(free_mb)
      [ "$f" -ge "$MINFREE" ] || {
        echo "only $f MB RAM available (MINFREE=$MINFREE): not starting site$k." \
             "Use SITES_COUNT=$((k - 1)) and run setup again."
        exit 1
      }
    fi
    echo "   site$k on $(vm_of $k):" \
         "$(on "$(vm_of $k)" "NAME=site$k TIMEOUT=600 ./experiments/measure/sync-time.sh $POOL_IP 3001")" \
         " [s, blocks, ready s, db kB, MB]"
  done
  echo "2. keys (made inside the containers) and public files"
  local pool1_container='$(source scripts/lib.sh; pool_container 1)'   # text: the chain host evaluates it
  : > "$STATE/addresses.txt"
  for k in $(sites); do
    vmx=$(vm_of $k); g=$(gid $k)
    # the key pair of the site gateway, made inside the site container (the secret key never leaves it)
    local keygen="mkdir -p $P0_DIR $SCRIPTS_IN_CTR && cd $P0_DIR"
    keygen="$keygen && cardano-cli conway address key-gen --verification-key-file gw$g.vkey"
    keygen="$keygen --signing-key-file gw$g.skey"
    keygen="$keygen && cardano-cli conway address build --payment-verification-key-file gw$g.vkey"
    keygen="$keygen --testnet-magic $MAGIC > gw$g.addr"
    keygen="$keygen && cardano-cli conway address key-hash --payment-verification-key-file gw$g.vkey > gw$g.pkh"
    on "$vmx" "docker exec site$k bash -c '$keygen'"
    echo "$(gname $k) $(on "$vmx" "docker exec site$k cat $P0_DIR/gw$g.addr")" >> "$STATE/addresses.txt"
    # public files only, by name (never the .skey files), pool 1 -> this site
    local public_files="gateway_write.plutus policy.id token.hex admin.addr"
    local tar_out="docker exec $pool1_container tar cf - -C $P0_DIR $public_files"
    local tar_in="docker exec -i site$k tar xf - -C $P0_DIR"
    if [ $SITES = local ]; then
      on "$POOL" "$tar_out | $tar_in"
    else
      on "$POOL" "$tar_out" | ssh -o BatchMode=yes "$vmx" "$tar_in"
    fi
    on "$vmx" "docker cp experiments/contract/in-container/. site$k:$SCRIPTS_IN_CTR/"
    # the key hash goes to pool 1 so that the administrator can enrol it
    pkh=$(on "$vmx" "docker exec site$k cat $P0_DIR/gw$g.pkh")
    on "$POOL" "docker exec $pool1_container bash -c 'echo $pkh > $P0_DIR/gw$g.pkh'"
  done
  cat "$STATE/addresses.txt"

  echo "3. funding (100 ADA + 10 ADA collateral each, test ADA)"
  local addrs; addrs=$(awk '{print $2}' "$STATE/addresses.txt" | tr '\n' ' ')
  local fund_cmd="docker cp experiments/multisite/in-container/ms-fund.sh $pool1_container:$SCRIPTS_IN_CTR/"
  fund_cmd="$fund_cmd && source scripts/lib.sh && docker exec \$(pool_container 1)"
  fund_cmd="$fund_cmd bash $SCRIPTS_IN_CTR/ms-fund.sh $MAGIC $addrs"
  on "$POOL" "$fund_cmd"
  # wait (up to 2 min) until each site node sees its funded wallet
  for k in $(sites); do
    a=$(sed -n "${k}p" "$STATE/addresses.txt" | awk '{print $2}')
    local utxo_query="docker exec site$k cardano-cli conway query utxo --address $a --output-json"
    utxo_query="$utxo_query --testnet-magic $MAGIC --socket-path /node.socket"
    for _ in $(seq 60); do
      on "$(vm_of $k)" "$utxo_query" 2>/dev/null | grep -q lovelace && break
      sleep 2
    done
  done
  echo "4. enrolment"
  for k in $(sites); do enrol $k; done
  echo "5. page: names of the new gateways"
  python3 - "$STATE/addresses.txt" "$ROOT/experiments/pipeline/gateways.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[2]))
for line in open(sys.argv[1]):
    n, a = line.split(); g[n] = a
json.dump(g, open(sys.argv[2], "w"), indent=2); open(sys.argv[2], "a").write("\n")
PY
  if [ $SITES = local ]; then
    push "$ROOT/experiments/pipeline/gateways.json" "$REPO/experiments/pipeline/gateways.json"
  else
    rsync -a "$ROOT/experiments/pipeline/gateways.json" "$POOL:$REPO/experiments/pipeline/gateways.json" \
      2> >(grep -v -e '^\*\*' >&2)
  fi
  echo "setup done. The page server must be restarted to read the new gateways.json" \
       "(demo.sh --step 6, then --step 1 --keep)."
}

# ======================================================================================================
# The commands (they use the helpers above)
# ======================================================================================================
# enrol K / revoke K: the administrator puts site gateway K on / takes it off the registry list
enrol() { echo "   $(pool "bash $SCRIPTS_IN_CTR/p1-enroll.sh $MAGIC $(gid $1)" | tail -1)"; }
revoke() { echo "   $(pool "bash $SCRIPTS_IN_CTR/p1-revoke.sh $MAGIC $(gid $1)" | tail -1)"; }

start_gw() {   # start_gw K RUNDIR: the gateway of site K (own node container, own wallet, own port and outbox)
  local k=$1 run=$2 gw_cmd
  gw_cmd="env SITE=site$k GATEWAY=$(gid $k) EXU='$EXU' python3 -u gateway.py --B 100 --T 10"
  gw_cmd="$gw_cmd --listen-port $(gport $k) --outbox $(obx $k $run) --gateway-id $(gname $k)"
  gw_cmd="$gw_cmd --submit command --submit-command '$HOME_REPO/experiments/multisite/submit_site.sh {file} {hash}'"
  gw_cmd="$gw_cmd --retry 5 --max-tries $MAXTRIES"
  on "$(vm_of $k)" "./experiments/demo/remote.sh start $(gwn $k) $HOME_REPO/experiments/pipeline \"$gw_cmd\"" | tail -1
}
start_sensors() {   # start_sensors K COUNT SEQ-OFFSET: COUNT sensors for the gateway of site K
  local k=$1 n=$2 off=$3 sensor_cmd
  sensor_cmd="python3 -u sensor.py --sensors $n --interval 1 --port $(gport $k) --first-id $(( k * 100 + 1 ))"
  sensor_cmd="$sensor_cmd --seq-start $(( $(date +%s) + 1000000 * off ))"
  on "$(vm_of $k)" \
    "./experiments/demo/remote.sh start $(sn $k) $HOME_REPO/experiments/pipeline \"$sensor_cmd\"" | tail -1
}

start() {
  local n=${1:-$SENSORS_DEFAULT} run k; run=/tmp/ms-run-$(date +%Y%m%d-%H%M%S)
  init_home
  for k in $(sites); do
    start_gw $k "$run"
    start_sensors $k "$n" $(( k + 10 ))
    echo "$run" > "$STATE/run-$k.txt"
  done
}

# gwrestart K: stop and start the gateway of site K on the SAME outbox (state and pending batches are kept)
gwrestart() {
  local k=$1 run; run=$(cat "$STATE/run-$k.txt")
  init_home
  on "$(vm_of $k)" "./experiments/demo/remote.sh stop $(gwn $k)" | tail -1
  start_gw $k "$run"
}

# sensors N: restart the sensors of all sites with N sensors each (1 reading/s each); the gateways keep running
sensors() {
  local n=$1 k
  init_home
  for k in $(sites); do
    on "$(vm_of $k)" "./experiments/demo/remote.sh stop $(sn $k)" >/dev/null
    start_sensors $k "$n" $(( k + 20 + n ))
  done
}

backlog() {   # backlog: one line with the number of pending batches at each site
  local k out="" outbox
  for k in $(sites); do
    outbox=$(obx $k "$(cat "$STATE/run-$k.txt")")
    out="$out $(on "$(vm_of $k)" "cd $outbox && grep -l '^pending' *.status 2>/dev/null | wc -l" | tr -d ' ')"
  done
  echo "$out"
}

stop() {
  local k
  for k in $(sites); do
    on "$(vm_of $k)" "./experiments/demo/remote.sh stop $(sn $k); ./experiments/demo/remote.sh stop $(gwn $k)" | tr '\n' ' '; echo
  done
}

status() {
  local k vmx run
  for k in $(sites); do
    vmx=$(vm_of $k); run=$(cat "$STATE/run-$k.txt" 2>/dev/null || echo none)
    # runs on the site machine: count the batch status files in the outbox
    local count_cmd="cd $(obx $k "$run") 2>/dev/null && echo \"sent \$(grep -l '^sent' *.status 2>/dev/null | wc -l)"
    count_cmd="$count_cmd  pending \$(grep -l '^pending' *.status 2>/dev/null | wc -l)"
    count_cmd="$count_cmd  dead \$(ls dead 2>/dev/null | wc -l)\" || echo no-outbox"
    echo "site$k ($vmx, $(gname $k)): $(on "$vmx" "$count_cmd")"
    on "$vmx" "tail -1 /tmp/demo-logs/$(gwn $k).log" | sed 's/^/    /'
  done
}

mem() {   # RAM of the machine and of every site node container (the node uses most of it)
  local k
  for k in $(sites); do
    echo "site$k node: $(on "$(vm_of $k)" "docker stats --no-stream --format '{{.MemUsage}}' site$k" | tail -1)"
  done
  on "$POOL" "free -m | head -2"
}

# cut K / uncut K: 100 % packet loss on the node of site K (tc/netem), and back to normal
cutoff() {
  on "$(vm_of $1)" "NAME=site$1 ./experiments/measure/netem.sh set 0 100" >/dev/null
  echo "site$1: cut off (100 % loss)"
}
reconnect() {
  on "$(vm_of $1)" "NAME=site$1 ./experiments/measure/netem.sh clear" >/dev/null
  echo "site$1: connected again"
}

teardown() {
  local k
  for k in $(sites); do revoke $k || true; done
  for k in $(sites); do
    on "$(vm_of $k)" "docker exec site$k rm -f $P0_DIR/gw$(gid $k).skey; docker rm -f site$k" >/dev/null 2>&1 || true
  done
  for k in $(sites); do
    on "$POOL" "docker exec \$(source scripts/lib.sh; pool_container 1) rm -f $P0_DIR/gw$(gid $k).pkh" \
      >/dev/null 2>&1 || true
  done
  if [ $SITES = local ]; then   # the page list goes back to what it was: the site names leave gateways.json (here and on the chain host)
    python3 - "$ROOT/experiments/pipeline/gateways.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
for n in ("GW03", "GW04", "GW05"): g.pop(n, None)
json.dump(g, open(sys.argv[1], "w"), indent=2); open(sys.argv[1], "a").write("\n")
PY
    push "$ROOT/experiments/pipeline/gateways.json" "$REPO/experiments/pipeline/gateways.json"
  fi
  echo "teardown done: site gateways revoked, nodes removed, site keys deleted"
}

# ======================================================================================================
# Main
# ======================================================================================================
case "${1:-}" in
  setup) setup;; start) start "${2:-}";; stop) stop;; status) status;; mem) mem;;
  cut) cutoff "${2:?site 1..3}";; uncut) reconnect "${2:?site 1..3}";;
  sensors) sensors "${2:?N}";; backlog) backlog;;
  gwrestart) gwrestart "${2:?1..3}";;
  enrol) enrol "${2:?1..3}";; revoke) revoke "${2:?1..3}";; teardown) teardown;;
  *) sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//';;
esac
