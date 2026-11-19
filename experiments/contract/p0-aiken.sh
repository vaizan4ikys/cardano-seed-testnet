#!/bin/bash
# Runs on the VM HOST (seedvm, or your own Ubuntu VM), not in the container. Phase 0: test, build and parameterise the three Aiken validators.
#   p0-aiken.sh <seed-txid-hex> <seed-index> <token-name-hex> <outdir>
# 1. aiken check (all unit tests must pass)  2. aiken build
# 3. registry_mint gets its two parameters: the seed output (OutputReference) and the token name -> the registry policy id
# 4. gateway_write and gateway_withdraw get the registry policy id and the token name
# Writes into <outdir>: registry_mint.plutus gateway_write.plutus gateway_withdraw.plutus registry.policy.aiken
# (cardano-cli script JSON). The registry policy id printed by `aiken blueprint policy` is checked against cardano-cli later.
# The Aiken program is ~/tools/aiken-1.1.24/aiken-<aarch64|x86_64>-unknown-linux-musl/aiken (the CPU name is detected, see
# scripts/tools.sh); another path: AIKEN=/path/to/aiken ./p0-aiken.sh ...   scripts/install-tools.sh downloads it.
# The first aiken check downloads the standard library (aiken-lang/stdlib v4.0.0) from github.com: the VM needs internet once.
set -eu
SEEDTX=$1; SEEDIX=$2; NAME=$3; OUT=$4
[ "$SEEDIX" -lt 24 ] || { echo "seed index must be < 24 for the one-byte CBOR integer used here"; exit 1; }
[ -f "$HOME/cardano-seed-testnet/scripts/tools.sh" ] || { echo "missing $HOME/cardano-seed-testnet/scripts/tools.sh (the repo must be in ~/cardano-seed-testnet)"; exit 1; }
. "$HOME/cardano-seed-testnet/scripts/tools.sh"   # sets AIKEN (CPU-dependent path, or your own AIKEN=...)
[ -x "$AIKEN" ] || { echo "aiken not found: $AIKEN (run ~/cardano-seed-testnet/scripts/install-tools.sh)"; exit 1; }
P=$HOME/cardano-seed-testnet/experiments/contract/gateway-registry
mkdir -p "$OUT"; cd "$P"
CHK=$($AIKEN check 2>&1 | grep -E "Summary" | tail -1); echo "aiken check:$CHK"
case "$CHK" in *" 0 errors"*) ;; *) echo "aiken check has errors"; exit 1;; esac
$AIKEN build > /dev/null 2>&1
# parameters as Plutus data CBOR: OutputReference = constructor 0 [bytes txid, int index];  token name = byte string (0x40+n, n<24)
REFCBOR="d8799f5820${SEEDTX}$(printf '%02x' "$SEEDIX")ff"
NLEN=$(( ${#NAME} / 2 )); NCBOR=$(printf '%02x' $((0x40 + NLEN)))$NAME
W=$(mktemp -d /tmp/p0-apply.XXXXXX); trap 'rm -rf "$W"' EXIT
cp -r aiken.toml aiken.lock lib validators build $W/; cp plutus.json $W/plutus.json
cd $W
apply2() {   # apply2 VALIDATOR PARAM1 PARAM2: two parameters in order, then convert to a cardano-cli script file
  $AIKEN blueprint apply -m $1 -v $1 -i plutus.json -o step1.json "$2" > /dev/null 2>&1
  $AIKEN blueprint apply -m $1 -v $1 -i step1.json -o step2.json "$3" > /dev/null 2>&1
  cp step2.json plutus-$1.json
}
apply2 registry_mint "$REFCBOR" "$NCBOR"
RPOL=$($AIKEN blueprint policy -m registry_mint -v registry_mint -i plutus-registry_mint.json 2>&1 | grep -oE '[0-9a-f]{56}' | tail -1)
[ -n "$RPOL" ] || { echo "could not compute the registry policy id"; exit 1; }
cp plutus-registry_mint.json plutus.json
$AIKEN blueprint convert -m registry_mint -v registry_mint > "$OUT/registry_mint.plutus"
echo "$RPOL" > "$OUT/registry.policy.aiken"
for V in gateway_write gateway_withdraw; do
  cp "$P/plutus.json" plutus.json
  apply2 $V "581c$RPOL" "$NCBOR"
  cp plutus-$V.json plutus.json
  $AIKEN blueprint convert -m $V -v $V > "$OUT/$V.plutus"
done
for V in registry_mint gateway_write gateway_withdraw; do echo "$V: $(wc -c < "$OUT/$V.plutus") bytes -> $OUT/$V.plutus"; done
echo "registry policy id (aiken): $RPOL"
