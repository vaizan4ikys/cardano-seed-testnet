#!/bin/bash
# Test 5: how many readings per second can ONE real gateway (one wallet, one batch in flight, waits for the block) carry?
# Stages of STAGE seconds with N sensors per site (1 reading/s each); samples the backlog (pending batches) every 30 s.
# Runs next to multisite.sh (on the Mac or on the chain VM); writes one CSV line per sample.
#   ./loadtest.sh results/test5.csv "10 20 30" 240       args: OUT.csv  STAGES (sensors per site)  STAGE seconds
# Environment: SITES_COUNT=1..3 (default 3) as in multisite.sh; PAGE = the page to ask (default http://127.0.0.1:<PAGE_PORT>
# from scripts/config.sh; on the chain VM it is the same address).
# Note: with SITES=local all sites share the CPUs of one machine; expect lower numbers than with three machines.
. "$(cd "$(dirname "$0")" && pwd)/../../scripts/config.sh"     # PAGE_PORT
OUT=${1:?out.csv}; STAGES=${2:-"10 20 30"}; STAGE=${3:-240}
N=${SITES_COUNT:-3}; PAGE=${PAGE:-http://127.0.0.1:$PAGE_PORT}
cd "$(dirname "$0")"

# CSV header: time, sensors per site, offered rate, then the pending batches per site and the batches seen on the page
header="time_utc,sensors_per_site,offered_readings_s_per_site"
for k in $(seq $N); do header="$header,pending_site$k"; done
for k in $(seq $N); do header="$header,gw0$((k + 2))"; done
echo "$header" > "$OUT"

for n in $STAGES; do
  ./multisite.sh sensors "$n" > /dev/null 2>&1          # restart the sensors with n per site
  end=$(( $(date +%s) + STAGE ))
  while [ "$(date +%s)" -lt "$end" ]; do
    sleep 30
    backlog=$(./multisite.sh backlog 2>/dev/null | tr -s ' ' ',' | sed 's/^,//')
    # batches per site gateway (GW03..) as the page counts them
    page_batches=$(curl -s -m 10 "$PAGE/api/state" | python3 -c "
import json,sys
d=json.load(sys.stdin); g={x['name']:x['batches'] for x in d['gateways']}
print(','.join(str(g.get('GW0%d' % (k + 2), 0)) for k in range($N)))" 2>/dev/null)
    echo "$(date -u +%T),$n,$n,$backlog,$page_batches" >> "$OUT"
  done
done
