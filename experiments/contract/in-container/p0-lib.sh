#!/bin/bash
# Sourced (not run) by the other p0-*.sh and p1-*.sh scripts INSIDE pool 1's container. The caller sets MAGIC first.
# After sourcing: the current folder is the work folder W (= $P0_DIR, default /tmp/p0), and these exist:
#   cli, tx_visible, wait_tx, tip_block, now_ms, biggest_pure_coin, min_fee, gw_utxos, mk_data_tx, submit_tx,
#   short_err, swap_registry, plutus_err, and the variables PW (policy id of gateway_write), RHEX ("RECEIPT" in hex),
#   EXU, EXU_STEPS, EXU_MEM (execution units we declare).
#
# The data transactions are built WITHOUT `transaction build` (so no node-side script check at build time):
# the node (ledger) is the one that accepts or refuses them at submit.
#   EXU="(steps,memory)"   execution units declared for the policy (default below)
#   META_FILE=file         mk_data_tx uses this metadata file (a real batch) instead of a made-up reading
#   P0_DIR=/tmp/p0         the work folder (keys, registry.ref ...)
export CARDANO_NODE_SOCKET_PATH=/node.socket
cli() { cardano-cli conway "$@"; }
W=${P0_DIR:-/tmp/p0}; cd $W
RHEX=$(printf 'RECEIPT' | od -An -tx1 | tr -d ' \n')
PW=$(cli transaction policyid --script-file gateway_write.plutus)
# Execution units we declare for the policy. NOTE the order of cardano-cli 11.2.3: (STEPS,MEMORY), i.e. (cpu,mem).
# Measured for a real tx: 23653611 steps / 74016 memory; here with ~10 % margin.
EXU=${EXU:-"(26100000,81000)"}
EXU_STEPS=$(echo "$EXU" | tr -d '() ' | cut -d, -f1); EXU_MEM=$(echo "$EXU" | tr -d '() ' | cut -d, -f2)
[ -f pp.json ] || cli query protocol-parameters --testnet-magic "$MAGIC" --out-file pp.json

# ---- waiting for the chain ----
tx_visible() { cli query utxo --tx-in "$1#0" --output-json --testnet-magic "$MAGIC" 2>/dev/null | grep -q lovelace; }
# wait_tx TXID: wait up to 60 s until output 0 of the transaction is visible (= it is in a block)
wait_tx() {
  local n=0
  until tx_visible "$1"; do
    sleep 0.5; n=$((n+1))
    [ $n -gt 120 ] && { echo "timeout waiting for $1"; return 1; }
  done
  return 0
}
tip_block() { cli query tip --testnet-magic "$MAGIC" | jq -r .block; }
now_ms() { date +%s%3N; }

# ---- helpers for wallets and fees ----
# biggest_pure_coin ADDRESS: prints "<txid#ix> <lovelace>" of the biggest coin that holds only lovelace (no tokens)
biggest_pure_coin() {
  cli query utxo --address "$1" --output-json --testnet-magic "$MAGIC" \
    | jq -r 'to_entries | map(select(.value.value|keys==["lovelace"])) | sort_by(-.value.value.lovelace)[0]
             | "\(.key) \(.value.value.lovelace)"'
}
# min_fee BODYFILE [WITNESSES]: prints the minimum fee of a transaction body (default: 1 witness)
min_fee() {
  cli transaction calculate-min-fee --tx-body-file "$1" --protocol-params-file pp.json \
    --witness-count "${2:-1}" --output-text | grep -o '^[0-9]*'
}

# gw_utxos G  -> sets PAY PAYLOV PAYTOK (biggest utxo, token count of RECEIPT in it)
#                and COLL COLLLOV (smallest pure-lovelace utxo, used as collateral)
gw_utxos() {
  local file=gw$1.utxo.json
  cli query utxo --address "$(cat gw$1.addr)" --output-json --testnet-magic "$MAGIC" > $file
  PAY=$(jq -r 'to_entries | sort_by(-.value.value.lovelace)[0].key' $file)
  PAYLOV=$(jq -r 'to_entries | sort_by(-.value.value.lovelace)[0].value.value.lovelace' $file)
  PAYTOK=$(jq -r --arg p "$PW" --arg t "$RHEX" \
    'to_entries | sort_by(-.value.value.lovelace)[0].value.value | (.[$p][$t] // 0)' $file)
  COLL=$(jq -r 'to_entries | map(select(.value.value|keys==["lovelace"]))
                | sort_by(.value.value.lovelace)[0].key' $file)
  COLLLOV=$(jq -r 'to_entries | map(select(.value.value|keys==["lovelace"]))
                   | sort_by(.value.value.lovelace)[0].value.value.lovelace' $file)
}

# ---- the data transaction of a gateway ----
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
  if [ -n "${META_FILE:-}" ]; then
    cp "$META_FILE" $tag.meta.json   # a real batch from the gateway program: sent byte for byte
  else
    printf '{"1000":{"sensor":"AGRI_001","t":"%s","seq":%s,"temp":2450,"scale":100}}\n' \
      "$(date -u +%FT%TZ)" "$SEQ$RANDOM" > $tag.meta.json
  fi
  h=$(sha256sum $tag.meta.json | cut -d' ' -f1); printf '{"bytes":"%s"}\n' "$h" > $tag.red.json
  body() {   # body FEE: the transaction body for a given fee (collateral = 150 % of the fee, rounded up)
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
  f=$(min_fee $tag.raw)
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

# ---- the registry coin ----
# swap_registry DATUMFILE LABEL: the administrator spends the CURRENT registry coin (it sits at the admin address, so the
# admin key witness is enough) and sends the registry token + the new inline datum to a new output. Only the registry
# coin is spent (fee comes out of its 5 ADA), so no other admin coin is touched. Sets REGNEW REGOLD REGFEE.
# The old coin and its datum are appended to registry.history; registry.ref points to the new coin when it is in a block.
swap_registry() {
  local datum=$1 label=$2 admin policy tok val key=admin f
  admin=$(cat admin.addr); policy=$(cat policy.id); tok=$(cat token.hex); REGOLD=$(cat registry.ref)
  [ -f registry.history ] \
    || echo "$(date -u +%FT%TZ) $REGOLD (initial registry coin; history file started later)" > registry.history
  val=$(cli query utxo --tx-in "$REGOLD" --output-json --testnet-magic "$MAGIC" | jq -r '.[].value.lovelace')
  rb() {   # rb FEE: the body that moves the registry token to the admin address with the new datum
    cli transaction build-raw --fee "$1" --tx-in "$REGOLD" --tx-out "$admin+$((val - $1))+1 $policy.$tok" \
      --tx-out-inline-datum-file "$datum" --out-file swap.raw > /dev/null
  }
  rb 200000
  f=$(min_fee swap.raw)
  rb "$f"; REGFEE=$f
  cli transaction sign --tx-body-file swap.raw --signing-key-file $key.skey --out-file swap.signed
  REGNEW=$(cli transaction txid --tx-file swap.signed | grep -o '[0-9a-f]\{64\}')#0
}

# plutus_err: two key lines out of a Plutus refusal (which is several KB: the whole script, the TxInfo and so on).
# The full text goes to $W/last_refusal.txt.
plutus_err() {
  tr '\n' ' ' | tee $W/last_refusal.txt \
    | grep -o 'ConwayUtxowFailure (UtxoFailure (UtxosFailure (ValidationTagMismatch Phase2Valid (FailedUnexpectedly (PlutusFailure' \
    | head -1
  grep -o 'The plutus evaluation error is: CekError.\{0,300\}' $W/last_refusal.txt | sed 's/\\nThe protocol.*//' | head -1
}
