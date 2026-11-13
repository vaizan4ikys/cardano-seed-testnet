#!/bin/bash
# Real gateways at three sites, each with its own node, its own wallet and its own sensors, sending through the registry contract.
# Run from the Mac; the chain (EXPOSE=1) and Kupo must run on seedvm, the load must be off. bash 3.2 compatible.
#
#   ./multisite.sh setup            nodes + wallets + funding + enrolment of the three site gateways (about 10 min)
#   ./multisite.sh start [N]        gateways + N sensors each (default 10, 1 reading/s each) at the three sites
#   ./multisite.sh stop             stops gateways and sensors (the outboxes stay)
#   ./multisite.sh status           per site: batches sent / pending / dead, last log line
#   ./multisite.sh cut SITE|uncut SITE   (SITE = 1..3) 100 % packet loss on the site's node
#   MAXTRIES=1000 ./multisite.sh gwrestart K   restart the gateway of site K on the same outbox (patient: no dead letters for network trouble)
#   ./multisite.sh enrol N | revoke N    registry: enrol/revoke site gateway N (1..3)
#   ./multisite.sh teardown         revoke all three, remove the nodes, delete the site keys (the wallets' coins stay on the chain)
#
# Site k (1..3): machine seedvm2/seedvm3/seedvm4, node container site$k, gateway G$((k+2)) = name GW0$((k+2)), sensors AGRI_${k}1..
# The key of each gateway is made inside its own container and never leaves it.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
POOL=seedvm; MAGIC=42; REPO=cardano-seed-testnet
VMS=(seedvm2 seedvm3 seedvm4)
GPORT=9100
EXU=${EXU:-"(40600000,132100)"}
MAXTRIES=${MAXTRIES:-5}                                     # failed submits before a batch goes to dead/ (the gateway default)
STATE=$HERE/state; mkdir -p "$STATE"                       # addresses (public) of the site gateways
on() { local vm=$1; shift; ssh -A -o BatchMode=yes "$vm" "cd $REPO && $*" 2> >(grep -v -e '^\*\*' >&2); }
ip_of() { ssh -o BatchMode=yes "$1" hostname -I 2>/dev/null | cut -d' ' -f1; }
vm_of() { echo "${VMS[$(( $1 - 1 ))]}"; }
gid() { echo "G$(( $1 + 2 ))"; }
gname() { echo "GW0$(( $1 + 2 ))"; }
pool() { on "$POOL" "source scripts/lib.sh && docker exec -e P0_DIR=/tmp/p0n \$(require_pool 1) $*"; }
SENSORS_DEFAULT=10

setup() {
  [ "$(on "$POOL" './experiments/load/load.sh status' | head -1)" = running ] && { echo "the load is running: stop it first"; exit 1; }
  local POOL_IP; POOL_IP=$(ip_of "$POOL")
  for vm in "${VMS[@]}" "$POOL"; do
    rsync -a --exclude results --exclude state "$ROOT/experiments/" "${vm}:$REPO/experiments/" 2> >(grep -v -e '^\*\*' >&2)
    [ "$vm" = "$POOL" ] && continue
    on "$vm" "./experiments/join-node/fetch-chain-files.sh seed@$POOL_IP" >/dev/null
    on "$vm" 'docker rm -f $(docker ps -aq --filter name=site) >/dev/null 2>&1; true' >/dev/null
  done
  on "$POOL" "docker cp experiments/contract/in-container/. \$(source scripts/lib.sh; pool_container 1):/tmp/p0-scripts/" >/dev/null
  echo "1. nodes (each one syncs from pool 1)"
  for k in 1 2 3; do
    echo "   site$k on $(vm_of $k): $(on "$(vm_of $k)" "NAME=site$k TIMEOUT=600 ./experiments/measure/sync-time.sh $POOL_IP 3001")  [s, blocks, ready s, db kB, MB]"
  done
  echo "2. keys (made inside the containers) and public files"
  : > "$STATE/addresses.txt"
  for k in 1 2 3; do
    vm=$(vm_of $k); g=$(gid $k)
    on "$vm" "docker exec site$k bash -c 'mkdir -p /tmp/p0n /tmp/p0-scripts && cd /tmp/p0n && cardano-cli conway address key-gen --verification-key-file gw$g.vkey --signing-key-file gw$g.skey && cardano-cli conway address build --payment-verification-key-file gw$g.vkey --testnet-magic $MAGIC > gw$g.addr && cardano-cli conway address key-hash --payment-verification-key-file gw$g.vkey > gw$g.pkh'"
    echo "$(gname $k) $(on "$vm" "docker exec site$k cat /tmp/p0n/gw$g.addr")" >> "$STATE/addresses.txt"
    # public files only, by name (never the .skey files), pool 1 -> this site
    on "$POOL" "docker exec \$(source scripts/lib.sh; pool_container 1) tar cf - -C /tmp/p0n gateway_write.plutus policy.id token.hex admin.addr" \
      | ssh -o BatchMode=yes "$vm" "docker exec -i site$k tar xf - -C /tmp/p0n"
    on "$vm" "docker cp experiments/contract/in-container/. site$k:/tmp/p0-scripts/"
    # the key hash goes to pool 1 so that the administrator can enrol it
    pkh=$(on "$vm" "docker exec site$k cat /tmp/p0n/gw$g.pkh")
    on "$POOL" "docker exec \$(source scripts/lib.sh; pool_container 1) bash -c 'echo $pkh > /tmp/p0n/gw$g.pkh'"
  done
  cat "$STATE/addresses.txt"
  echo "3. funding (100 ADA + 10 ADA collateral each, test ADA)"
  local addrs; addrs=$(awk '{print $2}' "$STATE/addresses.txt" | tr '\n' ' ')
  on "$POOL" "docker cp experiments/multisite/in-container/ms-fund.sh \$(source scripts/lib.sh; pool_container 1):/tmp/p0-scripts/ && source scripts/lib.sh && docker exec \$(pool_container 1) bash /tmp/p0-scripts/ms-fund.sh $MAGIC $addrs"
  for k in 1 2 3; do
    a=$(sed -n "${k}p" "$STATE/addresses.txt" | awk '{print $2}')
    for _ in $(seq 60); do on "$(vm_of $k)" "docker exec site$k cardano-cli conway query utxo --address $a --output-json --testnet-magic $MAGIC --socket-path /node.socket" 2>/dev/null | grep -q lovelace && break; sleep 2; done
  done
  echo "4. enrolment"
  for k in 1 2 3; do enrol $k; done
  echo "5. page: names of the new gateways"
  python3 - "$STATE/addresses.txt" "$ROOT/experiments/pipeline/gateways.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[2]))
for line in open(sys.argv[1]):
    n, a = line.split(); g[n] = a
json.dump(g, open(sys.argv[2], "w"), indent=2); open(sys.argv[2], "a").write("\n")
PY
  rsync -a "$ROOT/experiments/pipeline/gateways.json" "$POOL:$REPO/experiments/pipeline/gateways.json" 2> >(grep -v -e '^\*\*' >&2)
  echo "setup done. The page server must be restarted to read the new gateways.json (demo.sh --step 6, then --step 1 --keep)."
}

enrol() { echo "   $(pool "bash /tmp/p0-scripts/p1-enroll.sh $MAGIC $(gid $1)" | tail -1)"; }
revoke() { echo "   $(pool "bash /tmp/p0-scripts/p1-revoke.sh $MAGIC $(gid $1)" | tail -1)"; }

start() {
  local n=${1:-$SENSORS_DEFAULT} run; run=/tmp/ms-run-$(date +%Y%m%d-%H%M%S)
  for k in 1 2 3; do
    local vm g; vm=$(vm_of $k); g=$(gid $k)
    on "$vm" "./experiments/demo/remote.sh start gw $HOME_REPO/experiments/pipeline \"env SITE=site$k GATEWAY=$g EXU='$EXU' python3 -u gateway.py --B 100 --T 10 --listen-port $GPORT --outbox $run/outbox --gateway-id $(gname $k) --submit command --submit-command '$HOME_REPO/experiments/multisite/submit_site.sh {file} {hash}' --retry 5 --max-tries $MAXTRIES\"" | tail -1
    on "$vm" "./experiments/demo/remote.sh start sensors $HOME_REPO/experiments/pipeline \"python3 -u sensor.py --sensors $n --interval 1 --port $GPORT --first-id $(( k * 100 + 1 )) --seq-start $(( $(date +%s) + 1000000 * (k + 10) ))\"" | tail -1
    echo "$run" > "$STATE/run-$k.txt"
  done
}
HOME_REPO=/home/seed/$REPO

gwrestart() {   # gwrestart K: stop and start the gateway of site K on the SAME outbox (state and pending batches are kept)
  local k=$1 vm g run; vm=$(vm_of $k); g=$(gid $k); run=$(cat "$STATE/run-$k.txt")
  on "$vm" "./experiments/demo/remote.sh stop gw" | tail -1
  on "$vm" "./experiments/demo/remote.sh start gw $HOME_REPO/experiments/pipeline \"env SITE=site$k GATEWAY=$g EXU='$EXU' python3 -u gateway.py --B 100 --T 10 --listen-port $GPORT --outbox $run/outbox --gateway-id $(gname $k) --submit command --submit-command '$HOME_REPO/experiments/multisite/submit_site.sh {file} {hash}' --retry 5 --max-tries $MAXTRIES\"" | tail -1
}

sensors() {   # sensors N: restart the sensors of all three sites with N sensors each (1 reading/s each); the gateways keep running
  local n=$1 k
  for k in 1 2 3; do
    on "$(vm_of $k)" "./experiments/demo/remote.sh stop sensors" >/dev/null
    on "$(vm_of $k)" "./experiments/demo/remote.sh start sensors $HOME_REPO/experiments/pipeline \"python3 -u sensor.py --sensors $n --interval 1 --port $GPORT --first-id $(( k * 100 + 1 )) --seq-start $(( $(date +%s) + 1000000 * (k + 20 + n) ))\"" | tail -1
  done
}

backlog() {   # backlog: one line with the number of pending batches at each site
  local k out=""
  for k in 1 2 3; do
    out="$out $(on "$(vm_of $k)" "cd $(cat "$STATE/run-$k.txt")/outbox && grep -l '^pending' *.status 2>/dev/null | wc -l" | tr -d ' ')"
  done
  echo "$out"
}

stop() {
  for k in 1 2 3; do
    on "$(vm_of $k)" "./experiments/demo/remote.sh stop sensors; ./experiments/demo/remote.sh stop gw" | tr '\n' ' '; echo
  done
}

status() {
  for k in 1 2 3; do
    local vm run; vm=$(vm_of $k); run=$(cat "$STATE/run-$k.txt" 2>/dev/null || echo none)
    echo "site$k ($vm, $(gname $k)): $(on "$vm" "cd $run/outbox 2>/dev/null && echo \"sent \$(grep -l '^sent' *.status 2>/dev/null | wc -l)  pending \$(grep -l '^pending' *.status 2>/dev/null | wc -l)  dead \$(ls dead 2>/dev/null | wc -l)\" || echo no-outbox")"
    on "$vm" "tail -1 /tmp/demo-logs/gw.log" | sed 's/^/    /'
  done
}

cutoff() { on "$(vm_of $1)" "NAME=site$1 ./experiments/measure/netem.sh set 0 100" >/dev/null; echo "site$1: cut off (100 % loss)"; }
reconnect() { on "$(vm_of $1)" "NAME=site$1 ./experiments/measure/netem.sh clear" >/dev/null; echo "site$1: connected again"; }

teardown() {
  for k in 1 2 3; do revoke $k || true; done
  for k in 1 2 3; do on "$(vm_of $k)" "docker exec site$k rm -f /tmp/p0n/gw$(gid $k).skey; docker rm -f site$k" >/dev/null 2>&1 || true; done
  for k in 1 2 3; do on "$POOL" "docker exec \$(source scripts/lib.sh; pool_container 1) rm -f /tmp/p0n/gw$(gid $k).pkh" >/dev/null 2>&1 || true; done
  echo "teardown done: site gateways revoked, nodes removed, site keys deleted"
}

case "${1:-}" in
  setup) setup;; start) start "${2:-}";; stop) stop;; status) status;;
  cut) cutoff "${2:?site 1..3}";; uncut) reconnect "${2:?site 1..3}";;
  sensors) sensors "${2:?N}";; backlog) backlog;;
  gwrestart) gwrestart "${2:?1..3}";;
  enrol) enrol "${2:?1..3}";; revoke) revoke "${2:?1..3}";; teardown) teardown;;
  *) sed -n 2,14p "$0";;
esac
