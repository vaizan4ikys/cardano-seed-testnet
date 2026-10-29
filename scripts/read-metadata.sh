#!/bin/bash
# Read back a message sent with send-metadata.sh, decrypting it if needed.
# Run on the VM. NET=2 reads messages sent to network 2.
#
#   ./scripts/read-metadata.sh <txid>                     plain message
#   ./scripts/read-metadata.sh <txid> -i reader.key       sent with -r/-R (age public keys)
#   ./scripts/read-metadata.sh <txid> -k "my secret"      sent with -k (shared password)
#   ./scripts/read-metadata.sh some.json -i reader.key    any metadata JSON, e.g. from an indexer
#
# <txid> is looked up as build/net-<N>/sent/<txid>.json. The JSON may be the full metadata
# {"674": {...}} or just the {"enc": ..., "msg": [...]} part.
set -eo pipefail
source "$(dirname "$0")/lib.sh"
SRC=${1:?usage: $0 <txid | file.json> [-i key file | -k password]}; shift
IDENT=""; PASS=""
while getopts "i:k:" opt; do
  case $opt in
    i) IDENT=$OPTARG ;;
    k) PASS=$OPTARG ;;
    *) awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 1 ;;
  esac
done
if [ -f "$SRC" ]; then FILE=$SRC; else FILE=$SENT/$SRC.json; fi
[ -f "$FILE" ] || { echo "not found: $FILE"; exit 1; }

# print "<enc>" on the first line, then the msg strings one per line
PARTS=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
d = d.get("674", d)
print(d.get("enc", "none"))
for s in d["msg"]:
    print(s)' "$FILE")
ENC=$(head -1 <<< "$PARTS")
BODY=$(tail -n +2 <<< "$PARTS")

case $ENC in
  none)  LIST=$(python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(json.dumps(d.get("674", d)["msg"]))' "$FILE") ;;
  age)   [ -n "$IDENT" ] || { echo "encrypted for public keys: pass your key file with -i"; exit 1; }
         LIST=$(age -d -i "$IDENT" <<< "$BODY") ;;
  basic) [ -n "$PASS" ] || { echo "encrypted with a password: pass it with -k"; exit 1; }
         LIST=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -a -k "$PASS" <<< "$BODY") ;;
  *)     echo "unknown encryption: $ENC"; exit 1 ;;
esac

# the message was split into 64-byte strings; join them back together
python3 -c 'import json, sys; print("".join(json.loads(sys.stdin.read())))' <<< "$LIST"
