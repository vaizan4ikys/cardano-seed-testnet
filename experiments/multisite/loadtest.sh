#!/bin/bash
# Test 5: how many readings per second can ONE real gateway (one wallet, one batch in flight, waits for the block) carry?
# Stages of STAGE seconds with N sensors per site (1 reading/s each); samples the backlog (pending batches) every 30 s.
#   ./loadtest.sh results/test5.csv "10 20 30" 240
OUT=${1:?out.csv}; STAGES=${2:-"10 20 30"}; STAGE=${3:-240}
cd "$(dirname "$0")"
echo "time_utc,sensors_per_site,offered_readings_s_per_site,pending_site1,pending_site2,pending_site3,gw03,gw04,gw05" > "$OUT"
for n in $STAGES; do
  ./multisite.sh sensors "$n" > /dev/null 2>&1
  end=$(( $(date +%s) + STAGE ))
  while [ "$(date +%s)" -lt "$end" ]; do
    sleep 30
    b=$(./multisite.sh backlog 2>/dev/null | tr -s ' ' ',' | sed 's/^,//')
    g=$(curl -s -m 10 http://127.0.0.1:8088/api/state | python3 -c "
import json,sys
d=json.load(sys.stdin); g={x['name']:x['batches'] for x in d['gateways']}; print('%s,%s,%s'%(g['GW03'],g['GW04'],g['GW05']))" 2>/dev/null)
    echo "$(date -u +%T),$n,$n,$b,$g" >> "$OUT"
  done
done
