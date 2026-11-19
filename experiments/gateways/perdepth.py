#!/usr/bin/env python3
"""Results of one gateways.sh run per depth (hops behind the pool).

Usage:
    python3 perdepth.py results/gateways-<date-time>

Reads   depths.txt                 one line per gateway: <gateway k> <depth> <machine>
        steps-R<total>-gw<k>.csv   the summary row of each gateway
        txs-R<total>-gw<k>.csv     one row per transaction
Writes  perdepth.csv in the same folder (and prints it): one row per step and depth: stored readings
        per second (confirmed transactions x batch / time from first to last confirmation), the waiting
        time (planned send time to block) p50/p90/p99, and the transactions not confirmed.
"""
import argparse
import csv
import glob
import re
from pathlib import Path
from typing import Dict, List

# columns of perdepth.csv (the "%" format in depth_row() must match this order)
HEADER = ("total_readings_s_target,depth,gateways,batch,offered_tx,confirmed_tx,lost,"
          "delivered_readings_s,lat_p50,lat_p90,lat_p99")


def read_depths(folder: Path) -> Dict[int, int]:
    """depths.txt -> {gateway number: depth}."""
    return {int(a): int(b) for a, b, _ in (line.split() for line in open(folder / "depths.txt"))}


def quantile(sorted_values: List[float], p: float) -> float:
    """Value at fraction p of an ascending list (NaN if the list is empty)."""
    if not sorted_values:
        return float("nan")
    return sorted_values[min(len(sorted_values) - 1, int(p * len(sorted_values)))]


def depth_row(folder: Path, total: int, d: int, depth: Dict[int, int]) -> str:
    """The perdepth.csv line of one total rate and one depth, added up over the gateways at that depth."""
    lat: List[float] = []                        # waiting time of every confirmed transaction
    conf: List[float] = []                       # confirmation time of every confirmed transaction
    offered = lost = gws = batch = 0
    for k, kd in depth.items():
        if kd != d:
            continue
        gws += 1
        st = list(csv.DictReader(open(folder / f"steps-R{total}-gw{k}.csv")))[-1]
        batch = int(st["batch"])
        offered += int(st["txs_planned"])
        lost += int(st["lost"])
        for r in csv.DictReader(open(folder / f"txs-R{total}-gw{k}.csv")):
            if r["confirmed_s"]:
                lat.append(float(r["confirmed_s"]) - float(r["planned_s"]))
                conf.append(float(r["confirmed_s"]))
    lat.sort()
    conf.sort()
    rate = (len(conf) - 1) * batch / (conf[-1] - conf[0]) if len(conf) > 1 else float("nan")
    return "%d,%d,%d,%d,%d,%d,%d,%.1f,%.2f,%.2f,%.2f" % (
        total, d, gws, batch, offered, len(conf), lost, rate,
        quantile(lat, .5), quantile(lat, .9), quantile(lat, .99))


def main() -> None:
    parser = argparse.ArgumentParser(description="Per-depth results of one gateways.sh run; writes perdepth.csv.")
    parser.add_argument("folder", type=Path, help="result folder of gateways.sh (results/gateways-<date-time>)")
    folder = parser.parse_args().folder
    depth = read_depths(folder)
    files = glob.glob(str(folder / "steps-R*-gw*.csv"))
    totals = sorted({int(re.search(r"steps-R(\d+)-", f).group(1)) for f in files})
    out = [HEADER]
    for total in totals:
        for d in sorted(set(depth.values())):
            out.append(depth_row(folder, total, d, depth))
    (folder / "perdepth.csv").write_text("\n".join(out) + "\n")
    print("\n".join(out))


if __name__ == "__main__":
    main()
