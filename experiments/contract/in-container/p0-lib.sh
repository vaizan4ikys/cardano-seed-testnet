#!/bin/bash
# Sourced by the other p0-*.sh scripts INSIDE pool 1's container. Needs: MAGIC (set by the caller), cwd /tmp/p0.
# Helpers for building data transactions WITHOUT `transaction build` (so no node-side script check at build time):
# the node (ledger) is the one that accepts or refuses them at submit.
export CARDANO_NODE_SOCKET_PATH=/node.socket
cli() { cardano-cli conway "$@"; }
W=${P0_DIR:-/tmp/p0}; cd $W
RHEX=$(printf 'RECEIPT' | od -An -tx1 | tr -d ' \n')
PW=$(cli transaction policyid --script-file gateway_write.plutus)
# execution units we declare for the policy. NOTE the order of cardano-cli 11.2.3: (STEPS,MEMORY), i.e. (cpu,mem).
# Measured for a real tx: 23653611 steps / 74016 memory; here with ~10 % margin.
EXU=${EXU:-"(26100000,81000)"}
EXU_STEPS=$(echo "$EXU" | tr -d '() ' | cut -d, -f1); EXU_MEM=$(echo "$EXU" | tr -d '() ' | cut -d, -f2)
[ -f pp.json ] || cli query protocol-parameters --testnet-magic "$MAGIC" --out-file pp.json

tx_visible() { cli query utxo --tx-in "$1#0" --output-json --testnet-magic "$MAGIC" 2>/dev/null | grep -q lovelace; }
wait_tx() { local n=0; until tx_visible "$1"; do sleep 0.5; n=$((n+1)); [ $n -gt 120 ] && { echo "timeout waiting for $1"; return 1; }; done; return 0; }
tip_block() { cli query tip --testnet-magic "$MAGIC" | jq -r .block; }
now_ms() { date +%s%3N; }

# gw_utxos G  -> sets PAY PAYLOV PAYTOK (biggest utxo, token count of RECEIPT in it) and COLL COLLLOV (smallest pure-lovelace utxo)
gw_utxos() {
  cli query utxo --address "$(cat gw$1.addr)" --output-json --testnet-magic "$MAGIC" > gw$1.utxo.json
  PAY=$(jq -r 'to_entries | sort_by(-.value.value.lovelace)[0].key' gw$1.utxo.json)
  PAYLOV=$(jq -r 'to_entries | sort_by(-.value.value.lovelace)[0].value.value.lovelace' gw$1.utxo.json)
  PAYTOK=$(jq -r --arg p "$PW" --arg t "$RHEX" 'to_entries | sort_by(-.value.value.lovelace)[0].value.value | (.[$p][$t] // 0)' gw$1.utxo.json)
  COLL=$(jq -r 'to_entries | map(select(.value.value|keys==["lovelace"])) | sort_by(.value.value.lovelace)[0].key' gw$1.utxo.json)
  COLLLOV=$(jq -r 'to_entries | map(select(.value.value|keys==["lovelace"])) | sort_by(.value.value.lovelace)[0].value.value.lovelace' gw$1.utxo.json)
}

# mk_data_tx G TAG PAYIN PAYLOV TOKIN COLLIN COLLLOV REF [EXTRA build-raw args...]
#  Builds + signs TAG.signed: spends PAYIN (holding TOKIN receipts), mints one more RECEIPT, one change output
#  (PAYLOV - fee, TOKIN+1 receipts), reference input REF, required signer = gateway key, metadata = a fresh reading.
#  Fee = min fee computed from a draft body (size * 1 + memory * priceMem + steps * priceSteps), fixed afterwards.
#  Sets TXID FEE SIZE CHANGE (= TXID#0) and NEXTLOV NEXTTOK (the change output's lovelace / receipt count).
SEQ=${SEQ:-0}
mk_data_tx() {
  local g=$1 tag=$2 pay=$3 lov=$4 tok=$5 coll=$6 clov=$7 ref=$8; shift 8
  local addr pkh h f
  addr=$(cat gw$g.addr); pkh=$(cat gw$g.pkh); SEQ=$((SEQ+1))
  if [ -n "${META_FILE:-}" ]; then cp "$META_FILE" $tag.meta.json   # a real batch from the gateway program: sent byte for byte
  else printf '{"1000":{"sensor":"AGRI_001","t":"%s","seq":%s,"temp":2450,"scale":100}}\n' "$(date -u +%FT%TZ)" "$SEQ$RANDOM" > $tag.meta.json; fi
  h=$(sha256sum $tag.meta.json | cut -d' ' -f1); printf '{"bytes":"%s"}\n' "$h" > $tag.red.json
  body() {   # body FEE
    local fee=$1 tc; shift; tc=$(( (fee * 150 + 99) / 100 ))
    cli transaction build-raw --protocol-params-file pp.json --fee "$fee" \
      --tx-in "$pay" --tx-in-collateral "$coll" --tx-total-collateral "$tc" \
      --tx-out-return-collateral "$addr+$((clov - tc))" \
      --read-only-tx-in-reference "$ref" \
      --tx-out "$addr+$(( lov - fee ))+$((tok + 1)) $PW.$RHEX" \
      --mint "1 $PW.$RHEX" --mint-script-file gateway_write.plutus --mint-redeemer-file $tag.red.json \
      --mint-execution-units "$EXU" --required-signer-hash "$pkh" \
      --metadata-json-file $tag.meta.json "$@" --out-file $tag.raw > /dev/null
  }
  body 300000 "$@"                       # draft with a rough fee, only to measure
  f=$(cli transaction calculate-min-fee --tx-body-file $tag.raw --protocol-params-file pp.json --witness-count 1 --output-text | grep -o '^[0-9]*')
  body "$f" "$@"                         # the real one (its fee field is a few bytes shorter, so f is never too low)
  cli transaction sign --tx-body-file $tag.raw --signing-key-file gw$g.skey --out-file $tag.signed
  FEE=$f; NEXTLOV=$((lov - f)); NEXTTOK=$((tok + 1))
  TXID=$(cli transaction txid --tx-file $tag.signed | grep -o '[0-9a-f]\{64\}'); CHANGE="$TXID#0"
  SIZE=$(( $(jq -r .cborHex $tag.signed | tr -d '\n' | wc -c) / 2 ))
}
# submit_tx TAG -> prints the node's answer; return code 0 = accepted into the mempool
submit_tx() { cli transaction submit --tx-file $1.signed --testnet-magic "$MAGIC" 2>&1; }

# short_err: first 380 characters of the node's refusal text (the full text is huge when a Plutus script fails)
short_err() { tr '\n' ' ' | sed 's/.*Error while submitting tx: //' | cut -c1-380; }

# swap_registry DATUMFILE LABEL: the administrator spends the CURRENT registry coin (it sits at the admin address, so the
# admin key witness is enough) and sends the registry token + the new inline datum to a new output. Only the registry
# coin is spent (fee comes out of its 5 ADA), so no other admin coin is touched. Sets REGNEW REGOLD REGFEE.
# The old coin and its datum are appended to registry.history; registry.ref points to the new coin when it is in a block.
swap_registry() {
  local datum=$1 label=$2 admin policy tok val key=admin f
  admin=$(cat admin.addr); policy=$(cat policy.id); tok=$(cat token.hex); REGOLD=$(cat registry.ref)
  [ -f registry.history ] || echo "$(date -u +%FT%TZ) $REGOLD (initial registry coin; history file started later)" > registry.history
  val=$(cli query utxo --tx-in "$REGOLD" --output-json --testnet-magic "$MAGIC" | jq -r '.[].value.lovelace')
  rb() { cli transaction build-raw --fee "$1" --tx-in "$REGOLD" --tx-out "$admin+$((val - $1))+1 $policy.$tok" \
           --tx-out-inline-datum-file "$datum" --out-file swap.raw > /dev/null; }
  rb 200000
  f=$(cli transaction calculate-min-fee --tx-body-file swap.raw --protocol-params-file pp.json --witness-count 1 --output-text | grep -o '^[0-9]*')
  rb "$f"; REGFEE=$f
  cli transaction sign --tx-body-file swap.raw --signing-key-file $key.skey --out-file swap.signed
  REGNEW=$(cli transaction txid --tx-file swap.signed | grep -o '[0-9a-f]\{64\}')#0
}

# plutus_err: two key lines out of a Plutus refusal (which is several KB: the whole script, the TxInfo and so on)
plutus_err() { tr '\n' ' ' | tee $W/last_refusal.txt | grep -o 'ConwayUtxowFailure (UtxoFailure (UtxosFailure (ValidationTagMismatch Phase2Valid (FailedUnexpectedly (PlutusFailure' | head -1
  grep -o 'The plutus evaluation error is: CekError.\{0,300\}' $W/last_refusal.txt | sed 's/\\nThe protocol.*//' | head -1; }
