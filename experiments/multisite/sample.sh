#!/bin/bash
# Samples the page's API once per INTERVAL seconds into a CSV (what the leader sees): tip, per gateway batches/receipts, live sensors, warnings.
#   ./sample.sh OUT.csv [SECONDS=1200] [INTERVAL=60]
OUT=${1:?out.csv}; TOTAL=${2:-1200}; IV=${3:-60}
echo "time_utc,tip_block,gw01,gw03,gw04,gw05,receipts_gw03,receipts_gw04,receipts_gw05,sensors_live,sensors_silent,warnings,rolled_back" > "$OUT"
end=$(( $(date +%s) + TOTAL ))
while [ "$(date +%s)" -lt "$end" ]; do
  curl -s -m 10 http://127.0.0.1:8088/api/state | python3 -c "
import json,sys,time
d=json.load(sys.stdin)
g={x['name']:x for x in d['gateways']}
s=d['sensors']; w=sum(len(b['warnings']) for b in d['batches'])
print(','.join(str(v) for v in [time.strftime('%H:%M:%S',time.gmtime()), d['tip']['block']]+[g[n]['batches'] for n in ('GW01','GW03','GW04','GW05')]+[g[n]['receipts'] for n in ('GW03','GW04','GW05')]+[sum(1 for x in s if not x['silent']),sum(1 for x in s if x['silent']),w,d['counts']['rolled_back']]))" >> "$OUT" 2>/dev/null
  sleep "$IV"
done
