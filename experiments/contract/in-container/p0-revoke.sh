#!/bin/bash
# Runs INSIDE pool 1's container. Phase 0, task 3: REVOCATION and RESTORE.
# The administrator replaces the registry coin with a new one holding an EMPTY list, then puts gateway A back on it.
#   p0-revoke.sh <magic>
set -eu
MAGIC=$1; . /tmp/p0-scripts/p0-lib.sh
ADMIN=$(cat admin.addr)
OLD=$(cat registry.ref); echo "== registry coin now (OLD): $OLD"
cli query utxo --tx-in "$OLD" --output-json --testnet-magic "$MAGIC" | jq -c '.[] | {value, inlineDatum}'
echo '{"list":[]}' > datum.empty.json
printf '{"list":[{"bytes":"%s"}]}\n' "$(cat gwA.pkh)" > datum.A.json

# --- A needs several separate coins so that the prepared transactions do not spend the same one
echo "== funding A with 3 extra coins of 10 ADA (admin, one tx)"
read -r IN VAL < <(cli query utxo --address "$ADMIN" --output-json --testnet-magic "$MAGIC" \
  | jq -r 'to_entries | map(select(.value.value|keys==["lovelace"])) | sort_by(-.value.value.lovelace)[0] | "\(.key) \(.value.value.lovelace)"')
cli transaction build-raw --fee 1000000 --tx-in "$IN" --tx-out "$(cat gwA.addr)+10000000" --tx-out "$(cat gwA.addr)+10000000" \
  --tx-out "$(cat gwA.addr)+10000000" --tx-out "$ADMIN+$((VAL - 31000000))" --out-file fundA.raw > /dev/null
cli transaction sign --tx-body-file fundA.raw --signing-key-file admin.skey --out-file fundA.signed
FID=$(cli transaction txid --tx-file fundA.signed | grep -o '[0-9a-f]\{64\}')
submit_tx fundA > /dev/null; wait_tx "$FID"
gw_utxos A; COLLIN=$COLL; COLLLOVIN=$COLLLOV
F1="$FID#0"; F2="$FID#1"; F3="$FID#2"
# --- prepare (NOT submit) three data txs of A that all reference the OLD registry coin
mk_data_tx A pre1 "$F1" 10000000 0 "$COLLIN" "$COLLLOVIN" "$OLD"; P1=$TXID   # D1: submitted just BEFORE the revoke tx, same second
mk_data_tx A pre2 "$F2" 10000000 0 "$COLLIN" "$COLLLOVIN" "$OLD"; P2=$TXID   # D2: submitted just AFTER the revoke tx, same second
mk_data_tx A pre3 "$F3" 10000000 0 "$COLLIN" "$COLLLOVIN" "$OLD"; P3=$TXID   # D3: stale tx, submitted only after the revoke is in a block
echo "== prepared: D1 $P1  D2 $P2  D3 $P3 (all reference OLD)"
swap_registry datum.empty.json revoke; NEW=$REGNEW; echo "== revoke tx: spends $REGOLD, creates $NEW (empty list), fee $REGFEE"

# --- the revocation, with D1 just before and D2 just after it
B0=$(tip_block); T0=$(now_ms)
O1=$(submit_tx pre1) && r1=accepted || r1="REFUSED: $(echo "$O1" | short_err)"
TR=$(now_ms); OR=$(submit_tx swap) && rr=accepted || rr="REFUSED: $(echo "$OR" | short_err)"
O2=$(submit_tx pre2) && r2=accepted || r2="REFUSED: $(echo "$O2" | short_err | cut -c1-260)"
echo "== (c) at +0 ms D1 (OLD ref) -> $r1"
echo "==     at +$((TR - T0)) ms REVOKE tx -> $rr   (tip block at start: $B0)"
echo "==     at +$(( $(now_ms) - T0 )) ms D2 (OLD ref, after revoke in the mempool) -> $r2"
declare -A gone=()
while [ "${#gone[@]}" -lt 3 ] && [ $(( $(now_ms) - T0 )) -lt 60000 ]; do
  for t in pre1:$P1 swap:${NEW%#0}; do n=${t%%:*}; id=${t#*:}; [ -n "${gone[$n]:-}" ] && continue
    cli query tx-mempool tx-exists "$id" --testnet-magic "$MAGIC" | grep -q true || gone[$n]="left mempool at +$(( $(now_ms) - T0 )) ms, tip block $(tip_block)"; done
  tx_visible "${NEW%#0}" && [ -z "${gone[visible]:-}" ] && gone[visible]="new registry coin visible at +$(( $(now_ms) - T0 )) ms, tip block $(tip_block)"
  sleep 0.1
done
echo "== revoke latency: D1: ${gone[pre1]:-?} | revoke: ${gone[swap]:-?} | ${gone[visible]:-?}"
echo "$(date -u +%FT%TZ) $NEW enrolled=[] revoked (replaced $OLD)" >> registry.history; echo "$NEW" > registry.ref
cli query utxo --tx-in "$NEW" --output-json --testnet-magic "$MAGIC" | jq -c '.[] | {value, inlineDatum}'
echo "== D1 in a block? A's coin F1 spent: $(cli query utxo --tx-in "$F1" --output-json --testnet-magic "$MAGIC" | jq -c 'length') (0 = spent = D1 is in a block, so a data tx placed before the revoke tx in the same block stayed valid)"

# --- (b) the stale data tx prepared BEFORE the revocation, submitted AFTER it
echo "== (b) D3 (references OLD, prepared before the revoke), submitted after it:"
submit_tx pre3 | short_err | cut -c1-260; echo

# --- (a) a data tx of A that references the NEW (empty) registry coin
gw_utxos A; mk_data_tx A late "$PAY" "$PAYLOV" "$PAYTOK" "$COLLIN" "$COLLLOVIN" "$NEW"
echo "== (a) data tx of A referencing the NEW registry coin ($NEW, empty list), size $SIZE fee $FEE:"
submit_tx late | plutus_err

# --- restore: A back on the list
swap_registry datum.A.json restore; echo "== restore tx: spends $REGOLD, creates $REGNEW (list = [gwA]), fee $REGFEE"
TS=$(now_ms); submit_tx swap > /dev/null; wait_tx "${REGNEW%#0}"; echo "== restore took $(( $(now_ms) - TS )) ms from submit until visible in a block"
echo "$(date -u +%FT%TZ) $REGNEW enrolled=[gwA $(cat gwA.pkh)] restored (replaced $REGOLD)" >> registry.history; echo "$REGNEW" > registry.ref
cli query utxo --tx-in "$REGNEW" --output-json --testnet-magic "$MAGIC" | jq -c '.[] | {value, inlineDatum}'
# smoke test: A writes again against the restored registry
gw_utxos A; mk_data_tx A again "$PAY" "$PAYLOV" "$PAYTOK" "$COLLIN" "$COLLLOVIN" "$(cat registry.ref)"
submit_tx again | head -c 100; echo; wait_tx "$TXID" && echo "== smoke test: A's data tx against the restored registry is in a block ($TXID)"
echo "== registry.history:"; cat registry.history
