#!/bin/bash
# Runs INSIDE pool 1's container. Phase 0, step 1: the work dir, the keys, and the ONE-TIME funding of the administrator.
#   p0-admin.sh <magic>        (FRESH=1 first deletes the work dir; only allowed for /tmp/<name>)
# - makes a DEDICATED administrator key (the genesis key utxo1 is NOT the registry administrator: other tools spend its coins)
# - makes the test gateway keys A (will be enrolled) and B (never enrolled)
# - funds the administrator ONCE from utxo1: a big coin (becomes the one-shot seed of the registry token) and a
#   separate collateral coin. After this utxo1 is not used by the registry at all.
# Writes (inside the work dir): admin.* gwA.* gwB.* token.hex seed.ref admin.coll. Secret keys are mode 600 and never printed.
# Environment: P0_DIR (work dir, default /tmp/p0, must look like /tmp/<name>), FRESH=1 (delete the work dir first).
set -eu
export CARDANO_NODE_SOCKET_PATH=/node.socket
cli() { cardano-cli conway "$@"; }
MAGIC=$1
W=${P0_DIR:-/tmp/p0}
[[ $W =~ ^/tmp/[A-Za-z0-9_-]+$ ]] || { echo "P0_DIR must look like /tmp/<name>, got '$W'"; exit 1; }
if [ "${FRESH:-}" = 1 ]; then rm -rf -- "$W"; echo "FRESH=1: work dir $W deleted"; fi
umask 077; mkdir -p "$W"; cd "$W"
[ -f admin.skey ] || cli address key-gen --verification-key-file admin.vkey --signing-key-file admin.skey
for g in A B; do
  [ -f gw$g.skey ] || cli address key-gen --verification-key-file gw$g.vkey --signing-key-file gw$g.skey
done
cli address build --payment-verification-key-file admin.vkey --testnet-magic "$MAGIC" > admin.addr
cli address key-hash --payment-verification-key-file admin.vkey > admin.pkh
for g in A B; do
  cli address key-hash --payment-verification-key-file gw$g.vkey > gw$g.pkh
  cli address build --payment-verification-key-file gw$g.vkey --testnet-magic "$MAGIC" > gw$g.addr
done
printf 'GW_REGISTRY' | od -An -tx1 | tr -d ' \n' > token.hex
chmod 600 ./*.skey

if [ -f seed.ref ]; then echo "administrator already funded (seed $(cat seed.ref)); nothing to do"; exit 0; fi
UKEY=/cardano/utxo-keys/utxo1/utxo                                   # the key itself is read here by cardano-cli only
UADDR=$(cli address build --payment-verification-key-file $UKEY.vkey --testnet-magic "$MAGIC")
# the biggest pure-lovelace coin of utxo1: IN = its txid#index, VAL = its lovelace
read -r IN VAL < <(cli query utxo --address "$UADDR" --output-json --testnet-magic "$MAGIC" \
  | jq -r 'to_entries | map(select(.value.value|keys==["lovelace"])) | sort_by(-.value.value.lovelace)[0]
           | "\(.key) \(.value.value.lovelace)"')
ADMIN=$(cat admin.addr); SEED_ADA=400000000; COLL_ADA=10000000
# body FEE: the funding transaction: a seed coin and a collateral coin for the administrator, the rest back to utxo1
body() {
  cli transaction build-raw --fee "$1" --tx-in "$IN" --tx-out "$ADMIN+$SEED_ADA" --tx-out "$ADMIN+$COLL_ADA" \
    --tx-out "$UADDR+$((VAL - SEED_ADA - COLL_ADA - $1))" --out-file fundadmin.raw > /dev/null
}
body 300000
cli query protocol-parameters --testnet-magic "$MAGIC" --out-file pp.json
F=$(cli transaction calculate-min-fee --tx-body-file fundadmin.raw --protocol-params-file pp.json \
      --witness-count 1 --output-text | grep -o '^[0-9]*')
body "$F"
cli transaction sign --tx-body-file fundadmin.raw --signing-key-file $UKEY.skey --out-file fundadmin.signed
ID=$(cli transaction txid --tx-file fundadmin.signed | grep -o '[0-9a-f]\{64\}')
cli transaction submit --tx-file fundadmin.signed --testnet-magic "$MAGIC" > /dev/null
n=0
until cli query utxo --tx-in "$ID#0" --output-json --testnet-magic "$MAGIC" 2>/dev/null | grep -q lovelace; do
  sleep 0.5; n=$((n+1))
  [ $n -gt 120 ] && { echo "funding tx not seen"; exit 1; }
done
echo "$ID#0" > seed.ref; echo "$ID#1" > admin.coll
echo "administrator funded once from utxo1 (tx $ID, fee $F): seed coin $ID#0 ($((SEED_ADA/1000000)) ADA)," \
     "collateral coin $ID#1 ($((COLL_ADA/1000000)) ADA); admin pkh $(cat admin.pkh)"
