#!/bin/bash
# Runs INSIDE pool 1's container. Phase 0, step 2: mint the registry token through the ONE-SHOT policy registry_mint.
#   p0-registry.sh <magic>      needs registry_mint.plutus (+ registry.policy.aiken) in the work dir, made by ../p0-aiken.sh
#                               work dir = $P0_DIR (default /tmp/p0)
# The token GW_REGISTRY is minted exactly once (the policy demands that the seed coin from p0-admin.sh is spent in the
# same transaction, and that exactly one token is minted). It lands at the administrator address with an inline datum =
# the list of enrolled gateway key hashes (only gateway A). If registry.ref already points to a live registry coin this
# script does nothing (and a second mint would be impossible anyway).
set -eu
export CARDANO_NODE_SOCKET_PATH=/node.socket
cli() { cardano-cli conway "$@"; }
MAGIC=$1
W=${P0_DIR:-/tmp/p0}; cd "$W"
live() { cli query utxo --tx-in "$1" --output-json --testnet-magic "$MAGIC" 2>/dev/null | grep -q lovelace; }
if [ -f registry.ref ] && live "$(cat registry.ref)"; then
  echo "registry already minted: coin $(cat registry.ref), policy $(cat policy.id)." \
       "Nothing to do (the policy is one-shot, a second token cannot be minted)."
  exit 0
fi
SEED=$(cat seed.ref); COLL=$(cat admin.coll); ADDR=$(cat admin.addr); TOK=$(cat token.hex)
POL=$(cli transaction policyid --script-file registry_mint.plutus)
[ "$POL" = "$(cat registry.policy.aiken)" ] \
  || { echo "policy id mismatch: cardano-cli $POL, aiken $(cat registry.policy.aiken)"; exit 1; }
live "$SEED" || { echo "seed coin $SEED is gone but there is no live registry coin:" \
                       "this work dir cannot mint the registry again. Use FRESH=1 for a new one."; exit 1; }
printf '{"list":[{"bytes":"%s"}]}\n' "$(cat gwA.pkh)" > datum.json      # enrolled: gateway A only
cli transaction build --tx-in "$SEED" --tx-in-collateral "$COLL" \
  --mint "1 $POL.$TOK" --mint-script-file registry_mint.plutus --mint-redeemer-value 0 \
  --tx-out "$ADDR+5000000+1 $POL.$TOK" --tx-out-inline-datum-file datum.json \
  --change-address "$ADDR" --testnet-magic "$MAGIC" --out-file reg.raw
cli transaction sign --tx-body-file reg.raw --signing-key-file admin.skey --out-file reg.signed
ID=$(cli transaction txid --tx-file reg.signed | grep -o '[0-9a-f]\{64\}')
cli transaction submit --tx-file reg.signed --testnet-magic "$MAGIC" > /dev/null
n=0
until live "$ID#0"; do
  sleep 0.5; n=$((n+1))
  [ $n -gt 120 ] && { echo "registry tx not seen"; exit 1; }
done
echo "$POL" > policy.id; echo "$ID#0" > registry.ref
echo "$(date -u +%FT%TZ) $ID#0 policy=$POL enrolled=[gwA $(cat gwA.pkh)] created (one-shot mint)" > registry.history
echo "registry coin $ID#0   registry policy $POL   token GW_REGISTRY" \
     "  enrolled: gwA $(cat gwA.pkh)   not enrolled: gwB $(cat gwB.pkh)"
cli query utxo --tx-in "$ID#0" --output-json --testnet-magic "$MAGIC" | jq -c '.[] | {value: .value, inlineDatum: .inlineDatum}'
