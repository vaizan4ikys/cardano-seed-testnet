#!/bin/bash
# Samples the page's API once per INTERVAL seconds into a CSV (what the leader sees): tip, per gateway batches/receipts, live sensors, warnings.
#   ./sample.sh OUT.csv [SECONDS=1200] [INTERVAL=60]
# PAGE=http://127.0.0.1:8088 is the page to ask. Gateways that are not on the page (fewer sites) count as 0.
OUT=${1:?out.csv}; TOTAL=${2:-1200}; IV=${3:-60}; PAGE=${PAGE:-http://127.0.0.1:8088}
echo "time_utc,tip_block,gw01,gw03,gw04,gw05,receipts_gw03,receipts_gw04,receipts_gw05,sensors_live,sensors_silent,warnings,rolled_back" > "$OUT"
end=$(( $(date +%s) + TOTAL ))
while [ "$(date +%s)" -lt "$end" ]; do
  curl -s -m 10 "$PAGE/api/state" | python3 -c "
import json,sys,time
d=json.load(sys.stdin)
g={x['name']:x for x in d['gateways']}
def b(n): return g.get(n, {}).get('batches', 0)
def r(n): return g.get(n, {}).get('receipts', 0)
s=d['sensors']; w=sum(len(b_['warnings']) for b_ in d['batches'])
print(','.join(str(v) for v in [time.strftime('%H:%M:%S',time.gmtime()), d['tip']['block']]+[b(n) for n in ('GW01','GW03','GW04','GW05')]+[r(n) for n in ('GW03','GW04','GW05')]+[sum(1 for x in s if not x['silent']),sum(1 for x in s if x['silent']),w,d['counts']['rolled_back']]))" >> "$OUT" 2>/dev/null
  sleep "$IV"
done
