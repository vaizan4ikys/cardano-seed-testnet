#!/bin/bash
# Test 5: how many readings per second can ONE real gateway (one wallet, one batch in flight, waits for the block) carry?
# Stages of STAGE seconds with N sensors per site (1 reading/s each); samples the backlog (pending batches) every 30 s.
#   ./loadtest.sh results/test5.csv "10 20 30" 240
# SITES_COUNT=1..3 (default 3) as in multisite.sh; PAGE=http://127.0.0.1:8088 is the page to ask (on the chain VM: the same address).
# Note: with SITES=local all sites share the CPUs of one machine; expect lower numbers than with three machines.
OUT=${1:?out.csv}; STAGES=${2:-"10 20 30"}; STAGE=${3:-240}
N=${SITES_COUNT:-3}; PAGE=${PAGE:-http://127.0.0.1:8088}
cd "$(dirname "$0")"
H="time_utc,sensors_per_site,offered_readings_s_per_site"
for k in $(seq $N); do H="$H,pending_site$k"; done
for k in $(seq $N); do H="$H,gw0$((k + 2))"; done
echo "$H" > "$OUT"
for n in $STAGES; do
  ./multisite.sh sensors "$n" > /dev/null 2>&1
  end=$(( $(date +%s) + STAGE ))
  while [ "$(date +%s)" -lt "$end" ]; do
    sleep 30
    b=$(./multisite.sh backlog 2>/dev/null | tr -s ' ' ',' | sed 's/^,//')
    g=$(curl -s -m 10 "$PAGE/api/state" | python3 -c "
import json,sys
d=json.load(sys.stdin); g={x['name']:x['batches'] for x in d['gateways']}
print(','.join(str(g.get('GW0%d' % (k + 2), 0)) for k in range($N)))" 2>/dev/null)
    echo "$(date -u +%T),$n,$n,$b,$g" >> "$OUT"
  done
done
