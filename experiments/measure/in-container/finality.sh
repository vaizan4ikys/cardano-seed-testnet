#!/bin/bash
# Runs INSIDE pool 1's container (started by ../finality.sh). N small transactions one after the other from
# utxo1; for each one: when it is in a block, and when the chain tip is K blocks deeper (K = the security
# parameter: from then on the block cannot be rolled back). Prints CSV: tx,inclusion_s,final_s,after_inclusion_s
# (all seconds from the submit of that transaction).
set -u
MAGIC=${MAGIC:?}; N=${N:-12}; K=${K:-60}
export CARDANO_NODE_SOCKET_PATH=/node.socket
KEY=/cardano/utxo-keys/utxo1/utxo
W=/tmp/finality; rm -rf $W; mkdir -p $W; cd $W || exit 1
cli() { cardano-cli conway "$@"; }
now() { date +%s.%N; }
tipblock() { cli query tip --testnet-magic "$MAGIC" | jq -r .block; }
ADDR=$(cli address build --payment-verification-key-file $KEY.vkey --testnet-magic "$MAGIC")
read -r IN VAL < <(cli query utxo --address "$ADDR" --output-json --testnet-magic "$MAGIC" | jq -r 'to_entries | sort_by(-.value.value.lovelace)[0] | "\(.key) \(.value.value.lovelace)"')
echo '{"1001": ["finality test"]}' > meta.json

( while [ ! -f stop ]; do echo "$(now) $(tipblock)" >> tips.txt; sleep 1; done ) &
POLL=$!
for i in $(seq "$N"); do
  VAL=$((VAL - 300000))
  cli transaction build-raw --fee 300000 --tx-in "$IN" --tx-out "$ADDR+$VAL" --metadata-json-file meta.json --out-file tx.raw >/dev/null || break
  cli transaction sign --tx-body-file tx.raw --signing-key-file $KEY.skey --out-file tx.signed || break
  ID=$(cli transaction txid --tx-file tx.signed | grep -o '[0-9a-f]\{64\}')
  TS=$(now)
  cli transaction submit --tx-file tx.signed --testnet-magic "$MAGIC" >/dev/null 2>&1 || { echo "submit $i failed" >&2; break; }
  until cli query utxo --tx-in "$ID#0" --output-json --testnet-magic "$MAGIC" 2>/dev/null | grep -q lovelace; do sleep 0.3; done
  echo "$i $ID $TS $(now) $(tipblock)" >> txs.txt
  IN="$ID#0"
done
LAST=$(tail -1 txs.txt | awk '{ print $5 }')
until [ "$(tipblock)" -ge $((LAST + K)) ]; do sleep 2; done
sleep 2; touch stop; wait $POLL
echo "tx,inclusion_s,final_s,after_inclusion_s"
awk -v K="$K" 'NR == FNR { t[NR] = $1; b[NR] = $2; n = NR; next }
  { for (j = 1; j <= n; j++) if (b[j] >= $5 + K) { printf "%d,%.1f,%.1f,%.1f\n", $1, $4 - $3, t[j] - $3, t[j] - $4; break } }' tips.txt txs.txt
