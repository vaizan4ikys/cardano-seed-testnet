#!/bin/bash
# Runs INSIDE pool 1's container after the Phase 3 run: registry list back to [A] only (what the demo expects), check it,
# delete the signing keys of the measurement (kP kS kR kX). Prints one line per check. Never prints keys.
#   ./p3-restore.sh <magic>
set -eu
MAGIC=${1:?usage: p3-restore.sh <magic>}; export MAGIC
. /tmp/p3-scripts/p3-lib.sh
cd $W
jq -n -c --arg a "$(cat $P0/gwA.pkh)" '[$a]' > listA.json
set_registry listA.json
L=$(registry_list)
[ "$L" = "[\"$(cat $P0/gwA.pkh)\"]" ] && echo "OK: registry list is exactly [A] (coin $(find_registry))" || { echo "FAIL: registry list is $L"; exit 1; }
rm -f kP.skey kS.skey kR.skey kX.skey && echo "OK: measurement signing keys deleted"
