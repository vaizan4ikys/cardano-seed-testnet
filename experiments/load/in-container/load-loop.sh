#!/bin/bash
# Runs INSIDE pool 1's container (started by ../load.sh). Keeps the mempool filled with ~15 KB
# metadata transactions so that the blocks stay almost full.
#
# Each transaction spends one UTxO of utxo2 and returns the rest to the same address as a new
# UTxO, so a UTxO is a "lane": one transaction per lane per block. The script first splits the
# funds into LANES lanes. With DRY_RUN=1 it builds and signs a few transactions, prints their
# size and submits nothing (it still queries the node, which changes nothing).
set -u
MAGIC=${MAGIC:?}
LANES=${LANES:-16}
STRINGS=${STRINGS:-230}
FILL_TXS=${FILL_TXS:-5}
MAX_DB_MB=${MAX_DB_MB:-2000}
STALL_SECONDS=${STALL_SECONDS:-120}
DRY_RUN=${DRY_RUN:-}
LANE_VALUE=1000000000          # lovelace per lane (1000 ADA, a fee is ~16000 lovelace)

KEY=/cardano/utxo-keys/utxo2/utxo
export CARDANO_NODE_SOCKET_PATH=/node.socket
# its own working directory: the measurements build their transactions in /tmp in the same container,
# and files with the same names (meta.json, tx.raw, tx.signed) would get mixed up
mkdir -p /tmp/load && cd /tmp/load
if [ -z "$DRY_RUN" ]; then echo $$ > /tmp/load.pid; trap 'rm -f /tmp/load.pid' EXIT; fi   # a dry run leaves a running load alone

log() { echo "$(date -u +%T) $*" | tee -a /tmp/load.log >&2; }
cli() { cardano-cli conway "$@"; }
ADDR=$(cli address build --payment-verification-key-file $KEY.vkey --testnet-magic "$MAGIC")

# the metadata: label 9999, STRINGS strings of 64 characters
PAD=$(printf 'x%.0s' $(seq 64))
jq -n --arg s "$PAD" --argjson n "$STRINGS" '{"9999": {"load": [range($n) | $s]}}' > meta.json

utxos() { cli query utxo --address "$ADDR" --output-json --testnet-magic "$MAGIC"; }   # JSON: {"txid#ix": {...}}
tx_size() { echo $(( $(jq -r .cborHex "$1" | wc -c) / 2 )); }                           # bytes of a signed tx

# build, sign (and submit unless DRY_RUN) one transaction that spends the given inputs
send() {            # send <tx-out options> -- <tx-in options>
  local outs=() ins=()
  while [ "$1" != "--" ]; do outs+=("$1"); shift; done; shift
  ins=("$@")
  cli transaction build --testnet-magic "$MAGIC" "${ins[@]}" ${outs[@]+"${outs[@]}"} --change-address "$ADDR" \
      --metadata-json-file meta.json --out-file tx.raw >/dev/null || return 1
  cli transaction sign --tx-body-file tx.raw --signing-key-file $KEY.skey --out-file tx.signed || return 1
  if [ -n "$DRY_RUN" ]; then log "dry run: signed tx of $(tx_size tx.signed) bytes (limit 16384), not submitted"; return 0; fi
  cli transaction submit --tx-file tx.signed --testnet-magic "$MAGIC" >/dev/null 2>>/tmp/load.err
}

# --- 1. make sure there are LANES UTxOs
COUNT=$(utxos | jq 'length')
if [ "$COUNT" -lt "$LANES" ]; then
  log "$COUNT UTxO(s) at utxo2: splitting into $LANES lanes"
  OUTS=(); for _ in $(seq $((LANES - 1))); do OUTS+=(--tx-out "$ADDR+$LANE_VALUE"); done
  INS=(); for t in $(utxos | jq -r 'keys[]'); do INS+=(--tx-in "$t"); done
  send "${OUTS[@]}" -- "${INS[@]}" || { log "split failed"; exit 1; }
  if [ -z "$DRY_RUN" ]; then
    until [ "$(utxos | jq 'length')" -ge "$LANES" ]; do sleep 1; done
    log "split done: $(utxos | jq 'length') lanes"
  fi
fi

# --- 2. dry run: one filled-up transaction, then stop
if [ -n "$DRY_RUN" ]; then
  FIRST=$(utxos | jq -r 'to_entries | max_by(.value.value.lovelace) | .key')
  send -- --tx-in "$FIRST" || { log "build failed"; exit 1; }
  log "a block of 64 KB (65536) fits $((65536 / $(tx_size tx.signed))) of these transactions"
  exit 0
fi

# --- 3. the loop
declare -A INFLIGHT          # input -> when it was spent, so one UTxO is not spent twice before its tx is in a block
SENT=0; LAST_BLOCK=-1; LAST_MOVE=$(date +%s); LAST_DB_CHECK=0
log "load running: $LANES lanes, keeping $FILL_TXS transactions in the mempool"
while [ ! -f /tmp/load.stop ]; do
  NOW=$(date +%s)

  # chain stalled? then add nothing until blocks come again
  BLOCK=$(cli query tip --testnet-magic "$MAGIC" 2>/dev/null | jq -r .block)
  if [ "$BLOCK" != "$LAST_BLOCK" ]; then LAST_BLOCK=$BLOCK; LAST_MOVE=$NOW; fi
  if [ $((NOW - LAST_MOVE)) -gt "$STALL_SECONDS" ]; then log "no new block for ${STALL_SECONDS}s: pausing"; sleep 10; continue; fi

  # chain database big enough?
  if [ $((NOW - LAST_DB_CHECK)) -ge 60 ]; then
    LAST_DB_CHECK=$NOW
    DB_MB=$(du -sm /cardano-db | cut -f1)
    if [ "$DB_MB" -ge "$MAX_DB_MB" ]; then log "chain database is $DB_MB MB (limit $MAX_DB_MB): stopping"; exit 0; fi
  fi

  # enough waiting in the mempool?
  WAITING=$(cli query tx-mempool info --testnet-magic "$MAGIC" | jq .numberOfTxs)
  if [ "$WAITING" -ge "$FILL_TXS" ]; then sleep 0.5; continue; fi

  for k in "${!INFLIGHT[@]}"; do [ $((NOW - INFLIGHT[$k])) -gt 90 ] && unset "INFLIGHT[$k]"; done
  LANE=""
  for t in $(utxos | jq -r 'to_entries[] | select(.value.value.lovelace > 5000000) | .key'); do
    [ -z "${INFLIGHT[$t]:-}" ] && { LANE=$t; break; }
  done
  [ -n "$LANE" ] || { sleep 0.5; continue; }

  if send -- --tx-in "$LANE"; then
    INFLIGHT[$LANE]=$NOW; SENT=$((SENT + 1)); echo $SENT > /tmp/load.count
    [ $((SENT % 50)) -eq 0 ] && log "$SENT transactions sent, mempool had $WAITING, tip block $BLOCK"
  else
    log "submit failed: $(tail -1 /tmp/load.err 2>/dev/null | cut -c1-120)"; sleep 1
  fi
done
log "stopped after $SENT transactions"
