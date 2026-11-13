#!/bin/bash
# Sourced by the p3-*.sh scripts INSIDE pool 1's container (see ../PHASE3-PLAN.md). Never prints key files.
#   /tmp/p0n  = the demo's work dir (administrator key, registry, policy, plutus files): used, never replaced
#   /tmp/p3   = the measurement's work dir (keys kP kS kR kX, lane coins, results)
export CARDANO_NODE_SOCKET_PATH=/node.socket
MAGIC=${MAGIC:-42}
P0=${P0_DIR:-/tmp/p0n}; W=${P3_DIR:-/tmp/p3}
mkdir -p "$W/results"
cli() { cardano-cli conway "$@"; }
RHEX=$(printf 'RECEIPT' | od -An -tx1 | tr -d ' \n')
PW=$(cli transaction policyid --script-file "$P0/gateway_write.plutus")
SCRIPT_BYTES=$(( $(jq -r .cborHex "$P0/gateway_write.plutus" | tr -d '\n' | wc -c) / 2 ))
now() { date +%s.%N; }
[ -f "$W/pp.json" ] || cli query protocol-parameters --testnet-magic "$MAGIC" --out-file "$W/pp.json"

tx_visible() { cli query utxo --tx-in "$1" --output-json --testnet-magic "$MAGIC" 2>/dev/null | grep -q lovelace; }
wait_txin() { local n=0; until tx_visible "$1"; do sleep 0.5; n=$((n+1)); [ $n -gt 240 ] && { echo "timeout waiting for $1"; return 1; }; done; return 0; }
txid_of() { cli transaction txid --tx-file "$1" | grep -o '[0-9a-f]\{64\}'; }
size_of() { echo $(( $(jq -r .cborHex "$1" | tr -d '\n' | wc -c) / 2 )); }
hex28() { head -c 28 /dev/urandom | od -An -tx1 | tr -d ' \n'; echo; }

# ---- the registry ------------------------------------------------------------------------------------------------
find_registry() {   # the one coin at the admin address that carries the registry token
  cli query utxo --address "$(cat $P0/admin.addr)" --output-json --testnet-magic "$MAGIC" \
    | jq -r --arg p "$(cat $P0/policy.id)" --arg t "$(cat $P0/token.hex)" \
        '[to_entries[] | select(.value.value[$p][$t] == 1) | .key] | if length == 1 then .[0] else empty end'
}
registry_list() { cli query utxo --tx-in "$(find_registry)" --output-json --testnet-magic "$MAGIC" | jq -c '[.[].inlineDatum.list[].bytes]'; }
# set_registry LISTFILE (a JSON array of 28-byte key hashes, hex): the administrator spends the registry coin AND the biggest
# other plain coin of the administrator (a list of 50 keys needs a bigger coin than 5 ADA), writes the new registry coin
# (12 ADA, token, inline datum) as output 0 and the change as output 1. Updates registry.ref of the demo's work dir.
set_registry() {
  local list=$1 admin policy tok old oval top tval f id
  admin=$(cat $P0/admin.addr); policy=$(cat $P0/policy.id); tok=$(cat $P0/token.hex)
  old=$(find_registry); [ -n "$old" ] || { echo "no registry coin"; return 1; }
  oval=$(cli query utxo --tx-in "$old" --output-json --testnet-magic "$MAGIC" | jq -r '.[].value.lovelace')
  read -r top tval < <(cli query utxo --address "$admin" --output-json --testnet-magic "$MAGIC" \
    | jq -r --arg old "$old" --arg c "$(cat $P0/admin.coll 2>/dev/null)" \
        'to_entries | map(select(.value.value|keys==["lovelace"])) | map(select(.key != $old and .key != $c)) | sort_by(-.value.value.lovelace)[0] | "\(.key) \(.value.value.lovelace)"')
  [ -n "$top" ] || { echo "no top-up coin"; return 1; }
  jq -c '{list: map({bytes: .})}' "$list" > $W/reg.datum.json
  rb() { cli transaction build-raw --protocol-params-file $W/pp.json --fee "$1" --tx-in "$old" --tx-in "$top" \
           --tx-out "$admin+12000000+1 $policy.$tok" --tx-out-inline-datum-file $W/reg.datum.json \
           --tx-out "$admin+$((oval + tval - 12000000 - $1))" --out-file $W/reg.raw > /dev/null; }
  rb 300000
  f=$(cli transaction calculate-min-fee --tx-body-file $W/reg.raw --protocol-params-file $W/pp.json --witness-count 1 --output-text | grep -o '^[0-9]*')
  rb "$f"
  cli transaction sign --tx-body-file $W/reg.raw --signing-key-file $P0/admin.skey --out-file $W/reg.signed
  id=$(txid_of $W/reg.signed)
  cli transaction submit --tx-file $W/reg.signed --testnet-magic "$MAGIC" > /dev/null || { echo "registry change refused"; return 1; }
  wait_txin "$id#0" || return 1
  echo "$id#0" > $P0/registry.ref; echo "$id#0" > $W/reg.ref
  echo "$(date -u +%FT%TZ) $id#0 (phase 3: list of $(jq length $list) keys)" >> $P0/registry.history
}

# ---- one variant: which key pays, which coins ---------------------------------------------------------------------
# use_variant P|S|R sets V KEYN ADDR PKH and (S, R) COLL COLLVAL REG REFSCR META RED
use_variant() {
  V=$1; KEYN=k$V; ADDR=$(cat $W/$KEYN.addr); PKH=$(cat $W/$KEYN.pkh)
  META=$W/batch100.json
  H=$(sha256sum "$META" | cut -d' ' -f1); printf '{"bytes":"%s"}\n' "$H" > $W/red.json; RED=$W/red.json
  if [ "$V" != P ]; then
    COLL=$(cat $W/coll.$V); COLLVAL=$(cli query utxo --tx-in "$COLL" --output-json --testnet-magic "$MAGIC" | jq -r '.[].value.lovelace')
    REG=$(find_registry)
  fi
  [ "$V" = R ] && REFSCR=$(cat $W/refscript.ref)
  return 0
}
# mk_tx IN VAL TOK FEE OUTBASE: build-raw + sign one transaction of the current variant; spends IN (VAL lovelace, TOK receipts).
# Needs EXU "(steps,mem)" for S and R. The change output is output 0 with VAL-FEE lovelace and TOK+1 receipts (S, R).
mk_tx() {
  local in=$1 val=$2 tok=$3 fee=$4 out=$5 tc
  tc=$(( (fee * 150 + 99) / 100 ))
  case $V in
    P) cli transaction build-raw --protocol-params-file $W/pp.json --fee "$fee" --tx-in "$in" --tx-out "$ADDR+$((val - fee))" \
         --metadata-json-file $META --out-file $out.raw > /dev/null ;;
    S) cli transaction build-raw --protocol-params-file $W/pp.json --fee "$fee" --tx-in "$in" \
         --tx-in-collateral "$COLL" --tx-total-collateral "$tc" --tx-out-return-collateral "$ADDR+$((COLLVAL - tc))" \
         --read-only-tx-in-reference "$REG" --tx-out "$ADDR+$((val - fee))+$((tok + 1)) $PW.$RHEX" \
         --mint "1 $PW.$RHEX" --mint-script-file $P0/gateway_write.plutus --mint-redeemer-file $RED --mint-execution-units "$EXU" \
         --required-signer-hash "$PKH" --metadata-json-file $META --out-file $out.raw > /dev/null ;;
    R) cli transaction build-raw --protocol-params-file $W/pp.json --fee "$fee" --tx-in "$in" \
         --tx-in-collateral "$COLL" --tx-total-collateral "$tc" --tx-out-return-collateral "$ADDR+$((COLLVAL - tc))" \
         --read-only-tx-in-reference "$REG" --tx-out "$ADDR+$((val - fee))+$((tok + 1)) $PW.$RHEX" \
         --mint "1 $PW.$RHEX" --mint-tx-in-reference "$REFSCR" --mint-plutus-script-v3 --mint-reference-tx-in-redeemer-file $RED \
         --mint-reference-tx-in-execution-units "$EXU" --policy-id "$PW" \
         --required-signer-hash "$PKH" --metadata-json-file $META --out-file $out.raw > /dev/null ;;
  esac || return 1
  cli transaction sign --tx-body-file $out.raw --signing-key-file $W/$KEYN.skey --out-file $out.signed
}
# min_fee IN VAL TOK: the minimum fee of a transaction of the current variant (from a draft), 0 if it cannot be built
min_fee() {
  local extra=""
  [ "$V" = R ] && extra="--reference-script-size $SCRIPT_BYTES"
  mk_tx "$1" "$2" "$3" 300000 $W/draft || return 1
  cli transaction calculate-min-fee --tx-body-file $W/draft.raw --protocol-params-file $W/pp.json --witness-count 1 $extra --output-text | grep -o '^[0-9]*'
}
