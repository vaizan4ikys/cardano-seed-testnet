#!/bin/bash
# Samples the page's API once per INTERVAL seconds into a CSV (what the leader sees):
# tip, per gateway batches/receipts, live sensors, warnings.
#   ./sample.sh OUT.csv [SECONDS=1200] [INTERVAL=60]
# Environment: PAGE = the page to ask (default http://127.0.0.1:<PAGE_PORT> from scripts/config.sh).
# Gateways that are not on the page (fewer sites) count as 0.
. "$(cd "$(dirname "$0")" && pwd)/../../scripts/config.sh"     # PAGE_PORT
OUT=${1:?out.csv}; TOTAL=${2:-1200}; IV=${3:-60}; PAGE=${PAGE:-http://127.0.0.1:$PAGE_PORT}
HEADER="time_utc,tip_block,gw01,gw03,gw04,gw05,receipts_gw03,receipts_gw04,receipts_gw05"
HEADER="$HEADER,sensors_live,sensors_silent,warnings,rolled_back"
echo "$HEADER" > "$OUT"
end=$(( $(date +%s) + TOTAL ))
while [ "$(date +%s)" -lt "$end" ]; do
  # one CSV line from the JSON of the page (a failed request adds nothing)
  curl -s -m 10 "$PAGE/api/state" | python3 -c "
import json,sys,time
d=json.load(sys.stdin)
g={x['name']:x for x in d['gateways']}
def b(n): return g.get(n, {}).get('batches', 0)
def r(n): return g.get(n, {}).get('receipts', 0)
s=d['sensors']; w=sum(len(b_['warnings']) for b_ in d['batches'])
row = [time.strftime('%H:%M:%S',time.gmtime()), d['tip']['block']]
row += [b(n) for n in ('GW01','GW03','GW04','GW05')]          # batches per gateway
row += [r(n) for n in ('GW03','GW04','GW05')]                 # receipts per site gateway
row += [sum(1 for x in s if not x['silent']), sum(1 for x in s if x['silent']), w, d['counts']['rolled_back']]
print(','.join(str(v) for v in row))" >> "$OUT" 2>/dev/null
  sleep "$IV"
done
