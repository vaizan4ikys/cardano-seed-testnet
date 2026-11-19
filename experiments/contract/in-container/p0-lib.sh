#!/bin/bash
# Sourced (not run) by the other p0-*.sh and p1-*.sh scripts INSIDE pool 1's container. The caller sets MAGIC first.
# After sourcing: the current folder is the work folder W (= $P0_DIR, default /tmp/p0), and these exist:
#   cli, tx_visible, wait_tx, wait_settled, tip_block, now_ms, biggest_pure_coin, min_fee, gw_utxos, mk_data_tx,
#   submit_tx, short_err, live_coin, find_registry, registry_coin, swap_registry, plutus_err, and the variables
#   PW (policy id of gateway_write; empty before gateway_write.plutus exists), RHEX ("RECEIPT" in hex),
#   EXU, EXU_STEPS, EXU_MEM (execution units we declare).
#
# A transaction can get lost on this lab chain: when two pools forge a block for the same slot, one block is dropped
# and the transactions only that block carried are NOT put back into the mempool. So the scripts that must not fail
# (the demo setup and the gateway) give wait_tx the signed file: it sends the same transaction again every 10 s until
# the tx is in a block. wait_settled also waits for one more block on top. The experiment scripts (p0-chain.sh,
# p0-revoke.sh, p0-guards.sh, p0-nodelevel.sh, p0-withdraw.sh, p0-write.sh) call wait_tx WITHOUT the signed file:
# they measure timings and refusals, so for them nothing is ever resent.
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
# gateway_write.plutus does not exist yet while p0-admin.sh runs (it only uses the waiting helpers), so PW may be empty
if [ -f gateway_write.plutus ]; then PW=$(cli transaction policyid --script-file gateway_write.plutus); else PW=""; fi
# Execution units we declare for the policy. NOTE the order of cardano-cli 11.2.3: (STEPS,MEMORY), i.e. (cpu,mem).
# Measured for a real tx: 23653611 steps / 74016 memory; here with ~10 % margin.
EXU=${EXU:-"(26100000,81000)"}
EXU_STEPS=$(echo "$EXU" | tr -d '() ' | cut -d, -f1); EXU_MEM=$(echo "$EXU" | tr -d '() ' | cut -d, -f2)
[ -f pp.json ] || cli query protocol-parameters --testnet-magic "$MAGIC" --out-file pp.json

# ---- waiting for the chain ----
tx_visible() { cli query utxo --tx-in "$1#0" --output-json --testnet-magic "$MAGIC" 2>/dev/null | grep -q lovelace; }
# in_mempool TXID: is the transaction still waiting in our node's mempool (not in a block yet)? (return code 0 = yes)
in_mempool() { cli query tx-mempool tx-exists "$1" --testnet-magic "$MAGIC" 2>/dev/null | grep -q true; }

# resend TXID SIGNED_FILE: send the same signed transaction again, because it is neither in a block nor in our
# node's mempool any more (the block that carried it was dropped). A resend is always safe: it spends the same inputs,
# so it can be in the chain only once. Return code 0 = sent again (or it turned up in a block meanwhile, or the node
# could not be asked: try again later); 1 = the node refuses it because its inputs are spent by ANOTHER transaction,
# so it can never get into a block any more and waiting longer is pointless.
resend() {
  local txid=$1 signed=$2 answer
  if answer=$(cli transaction submit --tx-file "$signed" --testnet-magic "$MAGIC" 2>&1); then
    echo "  the transaction was lost (not in a block, not in the mempool): sent the same transaction again" >&2
    return 0
  fi
  sleep 1; tx_visible "$txid" && return 0          # it got into a block in the meantime
  # the node says so in one of two ways: "All inputs are spent" (its mempool check) or BadInputsUTxO (the ledger)
  if echo "$answer" | grep -q -E 'All inputs are spent|BadInputsUTxO'; then
    echo "  cannot send it again: its inputs are spent by another transaction" >&2; return 1
  fi
  echo "  sending it again failed (will try again): $(echo "$answer" | short_err | head -c 150)" >&2
  return 0
}

# wait_tx TXID [SIGNED_FILE [MAX_SECONDS]]: wait until output 0 of the transaction is visible (= it is in a block).
# Without SIGNED_FILE: wait up to 60 s and never send anything (the experiment scripts rely on this).
# With SIGNED_FILE (the signed transaction file): wait up to MAX_SECONDS (default 90). Every 10 s that the tx is
# neither in a block nor in our node's mempool, send the same signed file again (resend). Why: if the block that
# carried our tx is dropped, no pool has the tx any more. A tx that only waits in the mempool is left alone.
# Gives up at once when a resend shows that the inputs are spent by another transaction.
# The notes go to stderr. Callers read only the LAST line on stdout (the gateway) or the last line (demo.sh), and
# the notes always come before it.
wait_tx() {
  local txid=$1 signed=${2:-} max=${3:-90} n=0 start=$SECONDS next_check
  if [ -z "$signed" ]; then
    until tx_visible "$txid"; do
      sleep 0.5; n=$((n+1))
      [ $n -gt 120 ] && { echo "timeout waiting for $txid"; return 1; }
    done
    return 0
  fi
  next_check=$((start + 10))
  until tx_visible "$txid"; do
    sleep 0.5
    [ $((SECONDS - start)) -ge "$max" ] && { echo "timeout waiting for $txid"; return 1; }
    [ $SECONDS -ge $next_check ] || continue
    next_check=$((SECONDS + 10))
    in_mempool "$txid" && continue                  # still waiting for a block: nothing to do
    tx_visible "$txid" && return 0
    resend "$txid" "$signed" \
      || { echo "the transaction $txid can no longer get into a block (its inputs are spent)"; return 1; }
  done
  return 0
}
tip_block() { cli query tip --testnet-magic "$MAGIC" | jq -r .block; }
# wait_settled TXID SIGNED_FILE: wait until the tx is in a block AND one more block is on top of it, and resend the
# signed file if the tx vanishes. Why: a block that carried our tx can still be replaced by an equally long block from
# another pool (a slot battle); the tx is then gone, and a script that already said "done" would be wrong.
# Steps: wait_tx (with resend) until visible; remember the tip block; wait until the tip is one higher while the tx
# stays visible; if it vanished meanwhile, send it again and start over (at most 4 rounds).
wait_settled() {
  local txid=$1 signed=$2 round seen_tip tip n
  for round in 1 2 3 4; do
    wait_tx "$txid" "$signed" || return 1
    seen_tip=$(tip_block); n=0
    while tx_visible "$txid"; do
      tip=$(tip_block)
      if [ "${tip:-0}" -gt "${seen_tip:-0}" ]; then return 0; fi
      sleep 1; n=$((n+1))
      [ $n -gt 60 ] && { echo "timeout: no block on top of the block with $txid"; return 1; }
    done
    echo "  the block with the transaction was replaced by another block" >&2
    resend "$txid" "$signed" \
      || { echo "the transaction $txid can no longer get into a block (its inputs are spent)"; return 1; }
  done
  echo "the transaction $txid keeps vanishing from the chain"; return 1
}
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
# live_coin TXIN: is this coin (txid#index) still unspent? (return code 0 = yes)
live_coin() { cli query utxo --tx-in "$1" --output-json --testnet-magic "$MAGIC" 2>/dev/null | grep -q lovelace; }

# find_registry: prints the registry coin found BY ITS TOKEN: the one coin at the admin address that carries the
# registry token. Prints nothing when there is not exactly one such coin.
find_registry() {
  cli query utxo --address "$(cat admin.addr)" --output-json --testnet-magic "$MAGIC" \
    | jq -r --arg p "$(cat policy.id)" --arg t "$(cat token.hex)" \
        '[to_entries[] | select(.value.value[$p][$t] == 1) | .key] | if length == 1 then .[0] else empty end'
}

# registry_coin: prints the current registry coin (txid#index). Normally that is the coin in registry.ref. If that coin
# is not live (a registry change was lost, or the block with it was replaced), it prints the coin found by its token
# instead and fixes registry.ref (with a short note on stderr). Return code 1 (and a message) if no coin is found.
registry_coin() {
  local ref found
  ref=$(cat registry.ref 2>/dev/null || true)
  if [ -n "$ref" ] && live_coin "$ref"; then echo "$ref"; return 0; fi
  found=$(find_registry)
  [ -n "$found" ] || { echo "no single registry coin found at the admin address" >&2; return 1; }
  # write it atomically (temporary file + mv): p1-batch.sh may do this at the same time for the other gateway
  echo "$found" > "registry.ref.tmp.$$" && mv "registry.ref.tmp.$$" registry.ref
  echo "note: registry.ref pointed to a coin that is gone (${ref:-none}); now using $found (found by its token)" >&2
  echo "$found"
}

# swap_registry DATUMFILE LABEL: the administrator spends the CURRENT registry coin (it sits at the admin address, so the
# admin key witness is enough) and sends the registry token + the new inline datum to a new output. Only the registry
# coin is spent (fee comes out of its 5 ADA), so no other admin coin is touched. Sets REGNEW REGOLD REGFEE.
# The current coin is registry_coin (registry.ref, or the coin found by the token when registry.ref is stale).
# The old coin and its datum are appended to registry.history; registry.ref points to the new coin when it is in a block.
# It only builds and signs swap.signed: the caller submits it and waits (wait_settled "${REGNEW%#0}" swap.signed).
swap_registry() {
  local datum=$1 label=$2 admin policy tok val key=admin f
  admin=$(cat admin.addr); policy=$(cat policy.id); tok=$(cat token.hex)
  REGOLD=$(registry_coin) || return 1
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
