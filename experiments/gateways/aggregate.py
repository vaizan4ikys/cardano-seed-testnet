#!/usr/bin/env python3
"""Adds up the gateways of one step folder and prints one row per step:  aggregate.py results/gateways-<date-time>

Reads steps-R<total>-gw<k>.csv (the summary row of each gateway) and txs-R<total>-gw<k>.csv (one row per
transaction); writes steps.csv with the totals over all gateways: readings offered and stored per second,
the waiting time (planned send time to block) over all transactions, lost transactions, and the lowest and
highest share one gateway got."""
import csv
import glob
import re
import statistics
import sys
from pathlib import Path

folder = Path(sys.argv[1])
steps = sorted({int(re.search(r"steps-R(\d+)-", f).group(1)) for f in glob.glob(str(folder / "steps-R*-gw*.csv"))})
out = ["total_readings_s_target,gateways,batch,offered_readings_s,delivered_readings_s,confirmed_rate_readings_s,delivered_min_gw,delivered_max_gw,lost,rejections,lat_p50,lat_p90,lat_p99,lat_max,mempool_max_bytes"]
for total in steps:
    rows = []
    for f in sorted(glob.glob(str(folder / f"steps-R{total}-gw*.csv"))):
        rows.append(list(csv.DictReader(open(f)))[-1])
    lat = []
    conf = []
    for f in sorted(glob.glob(str(folder / f"txs-R{total}-gw*.csv"))):
        for r in csv.DictReader(open(f)):
            if r["confirmed_s"]:
                lat.append(float(r["confirmed_s"]) - float(r["planned_s"]))
                conf.append(float(r["confirmed_s"]))
    lat.sort()
    conf.sort()
    # readings stored per second from the first to the last confirmation: over a long step this is the sustained rate
    rate = (len(conf) - 1) * int(rows[0]["batch"]) / (conf[-1] - conf[0]) if len(conf) > 1 else float("nan")
    q = lambda p: lat[min(len(lat) - 1, int(p * len(lat)))] if lat else float("nan")
    delivered = [float(r["delivered_readings_s"]) for r in rows]
    out.append("%d,%d,%s,%.1f,%.1f,%.1f,%.1f,%.1f,%d,%d,%.2f,%.2f,%.2f,%.2f,%d" % (
        total, len(rows), rows[0]["batch"], sum(float(r["offered_readings_s"]) for r in rows), sum(delivered), rate,
        min(delivered), max(delivered), sum(int(r["lost"]) for r in rows), sum(int(r["rejections"]) for r in rows),
        q(0.5), q(0.9), q(0.99), lat[-1] if lat else float("nan"), max(int(r["mempool_max_bytes"]) for r in rows)))
(folder / "steps.csv").write_text("\n".join(out) + "\n")
print("\n".join(out))
