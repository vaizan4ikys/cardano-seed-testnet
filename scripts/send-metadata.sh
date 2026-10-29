#!/bin/bash
# Put a text message on the chain, in the metadata of a transaction (label 674).
#
#   ./scripts/send-metadata.sh                          "Hello World!"
#   ./scripts/send-metadata.sh -m "temp-01: 21.4"       your own message
#   ./scripts/send-metadata.sh -k "secret" -m "..."     encrypted with a shared password
#   ./scripts/send-metadata.sh -r age1... -m "..."      encrypted for an age public key (repeat -r for more)
#   ./scripts/send-metadata.sh -R readers.txt -m "..."  same, keys from a file (one per line)
#   NET=2 ./scripts/send-metadata.sh ...                send to network 2
#
# Encryption happens here, on the host, so only encrypted text reaches the chain.
# The metadata is also saved as build/net-<N>/sent/<txid>.json; read it back with
# ./scripts/read-metadata.sh <txid>
set -eo pipefail
source "$(dirname "$0")/lib.sh"

usage() { awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 1; }

MESSAGE="Hello World!"
PASSWORD=""
AGE_KEYS=()
while getopts "m:k:r:R:" opt; do
  case $opt in
    m) MESSAGE=$OPTARG ;;
    k) PASSWORD=$OPTARG ;;
    r) AGE_KEYS+=(-r "$OPTARG") ;;
    R) AGE_KEYS+=(-R "$OPTARG") ;;
    *) usage ;;
  esac
done

# The message as a JSON list of strings. Cardano allows 64 bytes per metadata string,
# so it is cut into pieces, always between characters (never inside a Cyrillic letter).
split_message() {
  python3 -c '
import json, sys
pieces, current = [], ""
for ch in sys.argv[1]:
    if len((current + ch).encode()) > 64:
        pieces.append(current)
        current = ""
    current += ch
pieces.append(current)
print(json.dumps(pieces, ensure_ascii=False))' "$1"
}

# lines of text -> "line1","line2",...   (encrypted output has lines of at most 64 characters)
as_json_strings() { sed 's/.*/"&"/' | paste -sd, -; }

PLAIN=$(split_message "$MESSAGE")
echo "plain: $PLAIN"

if [ ${#AGE_KEYS[@]} -gt 0 ]; then
  command -v age >/dev/null || { echo "age is not installed"; exit 1; }
  ENCRYPTED=$(printf '%s' "$PLAIN" | age -a "${AGE_KEYS[@]}" | as_json_strings)
  METADATA="{\"674\": {\"enc\": \"age\", \"msg\": [$ENCRYPTED]}}"
elif [ -n "$PASSWORD" ]; then
  ENCRYPTED=$(printf '%s' "$PLAIN" | openssl enc -e -aes-256-cbc -pbkdf2 -iter 10000 -a -k "$PASSWORD" | as_json_strings)
  METADATA="{\"674\": {\"enc\": \"basic\", \"msg\": [$ENCRYPTED]}}"
else
  METADATA="{\"674\": {\"msg\": $PLAIN}}"
fi

# build, sign and submit inside pool 1's container (output is shown and also captured)
OUTPUT=$(docker exec -i "$(require_pool 1)" bash -s -- "$MAGIC" "$METADATA" \
           < "$ROOT/scripts/in-container/submit-metadata.sh" | tee /dev/stderr)

TXID=$(sed -n 's/^txid: //p' <<< "$OUTPUT")
mkdir -p "$SENT"
printf '%s\n' "$METADATA" > "$SENT/$TXID.json"
echo "saved: $SENT/$TXID.json"
