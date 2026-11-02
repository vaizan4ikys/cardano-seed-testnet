#!/usr/bin/env python3
"""Per depth (hops behind the pool) results of one gateways run:  perdepth.py results/<run>
Needs depths.txt (gateway k, depth, machine) and txs-R<total>-gw<k>.csv. One row per step and depth:
stored readings per second (confirmed transactions x batch / time from first to last confirmation),
the waiting time (planned send time to block) p50/p90/p99, and the transactions not confirmed."""
import csv, glob, re, sys
from pathlib import Path
folder = Path(sys.argv[1])
depth = {int(a): int(b) for a, b, _ in (l.split() for l in open(folder / "depths.txt"))}
steps = sorted({int(re.search(r"steps-R(\d+)-", f).group(1)) for f in glob.glob(str(folder / "steps-R*-gw*.csv"))})
out = ["total_readings_s_target,depth,gateways,batch,offered_tx,confirmed_tx,lost,delivered_readings_s,lat_p50,lat_p90,lat_p99"]
for total in steps:
    for d in sorted(set(depth.values())):
        lat, conf, offered, lost, gws, batch = [], [], 0, 0, 0, 0
        for k, kd in depth.items():
            if kd != d:
                continue
            gws += 1
            st = list(csv.DictReader(open(folder / f"steps-R{total}-gw{k}.csv")))[-1]
            batch = int(st["batch"]); offered += int(st["txs_planned"]); lost += int(st["lost"])
            for r in csv.DictReader(open(folder / f"txs-R{total}-gw{k}.csv")):
                if r["confirmed_s"]:
                    lat.append(float(r["confirmed_s"]) - float(r["planned_s"])); conf.append(float(r["confirmed_s"]))
        lat.sort(); conf.sort()
        rate = (len(conf) - 1) * batch / (conf[-1] - conf[0]) if len(conf) > 1 else float("nan")
        q = lambda p: lat[min(len(lat) - 1, int(p * len(lat)))] if lat else float("nan")
        out.append("%d,%d,%d,%d,%d,%d,%d,%.1f,%.2f,%.2f,%.2f" % (total, d, gws, batch, offered, len(conf), lost, rate, q(.5), q(.9), q(.99)))
(folder / "perdepth.csv").write_text("\n".join(out) + "\n")
print("\n".join(out))
