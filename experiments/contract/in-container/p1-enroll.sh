#!/bin/bash
# Runs INSIDE pool 1's container. Phase 1: ENROL a gateway (adds its key hash to the registry list).
#   P0_DIR=/tmp/p0n ./p1-enroll.sh <magic> A|B
# The administrator (dedicated admin key) spends the CURRENT registry coin and creates a new one with the new inline
# datum {"list":[...]} (swap_registry in p0-lib.sh: only the registry coin is spent, the fee comes out of its 5 ADA).
# The old list is kept, no duplicates; if the gateway is already on the list nothing is changed (idempotent).
# Waits until the new coin is in a block, updates registry.ref and registry.history, prints one readable line.
# p1-revoke.sh runs this same script with P1_ACTION=remove. Keys are never printed.
set -eu
MAGIC=${1:?usage: p1-enroll.sh <magic> A|B}; G=${2:?usage: p1-enroll.sh <magic> A|B}
ACTION=${P1_ACTION:-add}
case "$G" in A|B) ;; *) echo "gateway must be A or B"; exit 1;; esac
. /tmp/p0-scripts/p0-lib.sh                       # sets W (= $P0_DIR), cli, swap_registry, wait_tx ...
T0=$(now_ms)
# one registry change at a time (a second one would spend the same coin)
exec 9> registry.lock
flock -w 120 9 || { echo "another enrol/revoke is running (lock registry.lock)"; exit 1; }

live() { cli query utxo --tx-in "$1" --output-json --testnet-magic "$MAGIC" 2>/dev/null | grep -q lovelace; }
REG=$(cat registry.ref)
if ! live "$REG"; then                            # registry.ref is stale: look for the one coin with the registry token
  REG=$(cli query utxo --address "$(cat admin.addr)" --output-json --testnet-magic "$MAGIC" \
    | jq -r --arg p "$(cat policy.id)" --arg t "$(cat token.hex)" \
        '[to_entries[] | select(.value.value[$p][$t] == 1) | .key] | if length == 1 then .[0] else empty end')
  [ -n "$REG" ] || { echo "no single registry coin found at the admin address"; exit 1; }
  echo "$REG" > registry.ref
fi
PKH=$(cat gw$G.pkh)
CUR=$(cli query utxo --tx-in "$REG" --output-json --testnet-magic "$MAGIC" | jq -c '[.[].inlineDatum.list[].bytes]')
HAVE=$(echo "$CUR" | jq -r --arg k "$PKH" 'index($k) != null')
if [ "$ACTION" = add ]; then
  if [ "$HAVE" = true ]; then echo "gateway $G is already enrolled: list size $(echo "$CUR" | jq length), nothing changed"; exit 0; fi
  NEW=$(echo "$CUR" | jq -c --arg k "$PKH" '. + [$k]'); WHAT=enrolled
else
  if [ "$HAVE" = false ]; then echo "gateway $G is not enrolled: list size $(echo "$CUR" | jq length), nothing changed"; exit 0; fi
  NEW=$(echo "$CUR" | jq -c --arg k "$PKH" 'map(select(. != $k))'); WHAT=revoked
fi
echo "$NEW" | jq -c '{list: map({bytes: .})}' > datum.p1.json
swap_registry datum.p1.json "p1-$WHAT-$G"          # sets REGNEW REGOLD REGFEE; uses registry.ref as the coin to spend
submit_tx swap > swap.out || { echo "submit of the registry change failed: $(short_err < swap.out)"; exit 1; }
wait_tx "${REGNEW%#0}" || { echo "registry change submitted but not seen in a block: $REGNEW"; exit 1; }
SIZE=$(echo "$NEW" | jq length)
echo "$(date -u +%FT%TZ) $REGNEW enrolled=$SIZE keys; gateway $G $WHAT (replaced $REGOLD)" >> registry.history
echo "$REGNEW" > registry.ref
echo "OK: gateway $G $WHAT: list size now $SIZE, new registry coin ${REGNEW%#0}#0 in a block, took $(( $(now_ms) - T0 )) ms"
