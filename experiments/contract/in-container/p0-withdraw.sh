#!/bin/bash
# Runs INSIDE pool 1's container. Phase 0, stretch task: ZERO-WITHDRAWAL TRIGGER instead of a receipt token.
#   1. registers the script stake credential of gateway_withdraw.plutus (certificate with deposit)
#   2. sends a data tx of gateway A that withdraws 0 lovelace from that stake address (this runs the script)
#   3. sends one from B (not enrolled) to show it is refused
#   p0-withdraw.sh <magic>      needs gateway_withdraw.plutus in the work dir $P0_DIR (default /tmp/p0)
set -eu
MAGIC=$1; . /tmp/p0-scripts/p0-lib.sh
REG=$(cat registry.ref); DEP=$(jq .stakeAddressDeposit pp.json)
STAKE=$(cli stake-address build --stake-script-file gateway_withdraw.plutus --testnet-magic "$MAGIC"); echo "$STAKE" > stake.addr
SHASH=$(cli transaction policyid --script-file gateway_withdraw.plutus)
echo "== script stake credential $SHASH, stake address $STAKE, deposit $DEP"
cli stake-address registration-certificate --stake-script-file gateway_withdraw.plutus \
  --key-reg-deposit-amt "$DEP" --out-file stake.reg.cert

if ! cli query stake-address-info --address "$STAKE" --testnet-magic "$MAGIC" | grep -q address; then
  echo "== registering. A plain certificate is refused (the script is a required witness):"
  gw_utxos A; addr=$(cat gwA.addr)
  mk() {   # mk FEE [w]: the registration transaction; with "w" the script is added as certificate witness
    local tc=$(( ($1 * 150 + 99) / 100 )) w=()
    [ "${2:-}" = w ] && w=(--certificate-script-file gateway_withdraw.plutus --certificate-redeemer-value 0 \
        --certificate-execution-units "(5000000,20000)" \
        --tx-in-collateral "$COLL" --tx-total-collateral "$tc" --tx-out-return-collateral "$addr+$((COLLLOV - tc))")
    cli transaction build-raw --protocol-params-file pp.json --fee "$1" --tx-in "$PAY" \
      --certificate-file stake.reg.cert "${w[@]}" \
      --tx-out "$addr+$((PAYLOV - $1 - DEP))+$PAYTOK $PW.$RHEX" --out-file reg.raw > /dev/null
  }
  mk 300000; f=$(min_fee reg.raw); mk "$f"
  cli transaction sign --tx-body-file reg.raw --signing-key-file gwA.skey --out-file reg.signed
  submit_tx reg | short_err | cut -c1-250; echo
  echo "== registering with the script as certificate witness (needs the publish handler):"
  mk 300000 w; f=$(min_fee reg.raw); mk "$f" w
  cli transaction sign --tx-body-file reg.raw --signing-key-file gwA.skey --out-file reg.signed
  RID=$(cli transaction txid --tx-file reg.signed | grep -o '[0-9a-f]\{64\}')
  OUT=$(submit_tx reg) && { echo "   accepted (fee $f)"; wait_tx "$RID"; } \
    || { echo "   REFUSED: $(echo "$OUT" | short_err | cut -c1-500)"; exit 1; }
fi
cli query stake-address-info --address "$STAKE" --testnet-magic "$MAGIC" | jq -c .

# ---- data tx with a ZERO withdrawal instead of a minted receipt
STAKE=$(cat stake.addr)
mk_wd_tx() {   # mk_wd_tx G TAG PAYIN PAYLOV TOKIN COLLIN COLLLOV REF "(steps,mem)"
  local g=$1 tag=$2 pay=$3 lov=$4 tok=$5 coll=$6 clov=$7 ref=$8 exu=$9 addr pkh h f out
  addr=$(cat gw$g.addr); pkh=$(cat gw$g.pkh)
  printf '{"1000":{"sensor":"AGRI_001","t":"%s","seq":%s,"temp":2450,"scale":100}}\n' \
    "$(date -u +%FT%TZ)" "$RANDOM" > $tag.meta.json
  h=$(sha256sum $tag.meta.json | cut -d' ' -f1); printf '{"bytes":"%s"}\n' "$h" > $tag.red.json
  out="$addr+"; [ "$tok" -gt 0 ] && tokstr="+$tok $PW.$RHEX" || tokstr=""
  body() {   # body FEE: the transaction with a zero withdrawal (collateral = 150 % of the fee, rounded up)
    local fee=$1 tc=$(( ($1 * 150 + 99) / 100 ))
    cli transaction build-raw --protocol-params-file pp.json --fee "$fee" --tx-in "$pay" --tx-in-collateral "$coll" \
      --tx-total-collateral "$tc" --tx-out-return-collateral "$addr+$((clov - tc))" --read-only-tx-in-reference "$ref" \
      --withdrawal "$STAKE+0" --withdrawal-script-file gateway_withdraw.plutus --withdrawal-redeemer-file $tag.red.json \
      --withdrawal-execution-units "$exu" --required-signer-hash "$pkh" --metadata-json-file $tag.meta.json \
      --tx-out "$addr+$((lov - fee))$tokstr" --out-file $tag.raw > /dev/null
  }
  body 300000
  f=$(min_fee $tag.raw)
  body "$f"; cli transaction sign --tx-body-file $tag.raw --signing-key-file gw$g.skey --out-file $tag.signed
  FEE=$f; TXID=$(cli transaction txid --tx-file $tag.signed | grep -o '[0-9a-f]\{64\}')
  SIZE=$(( $(jq -r .cborHex $tag.signed | tr -d '\n' | wc -c) / 2 ))
}
echo "== B (not enrolled) with a zero withdrawal: the node must refuse"
gw_utxos B; mk_wd_tx B wdB "$PAY" "$PAYLOV" "$PAYTOK" "$COLL" "$COLLLOV" "$REG" "$EXU"
OUT=$(submit_tx wdB) && { echo "   UNEXPECTED: accepted"; exit 1; } \
  || { echo "   REFUSED by the node:"; echo "$OUT" | plutus_err; }
echo "== A (enrolled) with a zero withdrawal, declared units $EXU (steps,memory)"
gw_utxos A; mk_wd_tx A wdA "$PAY" "$PAYLOV" "$PAYTOK" "$COLL" "$COLLLOV" "$REG" "$EXU"
UNITS=$(cli transaction calculate-plutus-script-cost online --testnet-magic "$MAGIC" --tx-file wdA.signed \
          | jq -c '.[0].executionUnits // .[0]')
echo "   size $SIZE bytes, fee $FEE; units the node measures: $UNITS"
OUT=$(submit_tx wdA) && { echo "   ACCEPTED"; wait_tx "$TXID" && echo "   in a block: $TXID"; } \
  || { echo "   REFUSED: $(echo "$OUT" | short_err | cut -c1-600)"; exit 1; }
cli query utxo --tx-in "$TXID#0" --output-json --testnet-magic "$MAGIC" | jq -c '.[] | .value'
# same recipe again with the exact units the node measured plus 2 %,
# to compare the fee with the mint version under the same rule
M=$(echo "$UNITS" | jq .memory); S=$(echo "$UNITS" | jq .steps)
gw_utxos A; mk_wd_tx A wdA2 "$PAY" "$PAYLOV" "$PAYTOK" "$COLL" "$COLLLOV" "$REG" "($((S * 102 / 100)),$((M * 102 / 100)))"
echo "== A again, units measured +2 %: size $SIZE bytes, fee $FEE"
submit_tx wdA2 > /dev/null && wait_tx "$TXID" && echo "   in a block"

# ---- size / fee comparison, all with the same rule (units = what the node measured + 2 %), built only, not submitted
echo "== comparison (built with the same recipe, not submitted):"
gw_utxos A
echo "   withdraw version: size $SIZE bytes, fee $FEE"
MINT_UNITS="(24126683,75496)"   # 2 % above the measured 23653611 steps / 74016 memory of the mint version
EXU="$MINT_UNITS" mk_data_tx A cmpmint "$PAY" "$PAYLOV" "$PAYTOK" "$COLL" "$COLLLOV" "$REG"
echo "   mint version:     size $SIZE bytes, fee $FEE   (units $MINT_UNITS)"
a=$(cat gwA.addr)
cli transaction build-raw --protocol-params-file pp.json --fee 300000 --tx-in "$PAY" \
  --tx-out "$a+$((PAYLOV - 300000))+$PAYTOK $PW.$RHEX" \
  --metadata-json-file wdA2.meta.json --out-file cmpplain.raw > /dev/null
f=$(min_fee cmpplain.raw)
echo "   plain data tx without any script (reference): fee $f = size $f bytes (fee per byte 1, no execution units)"
