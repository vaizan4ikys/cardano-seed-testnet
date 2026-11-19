#!/usr/bin/env python3
"""Adds up the gateways of one run of gateways.sh: one row per step (total rate).

Usage:
    python3 aggregate.py results/gateways-<date-time>

Reads   steps-R<total>-gw<k>.csv  the summary row of each gateway (the last line is used)
        txs-R<total>-gw<k>.csv    one row per transaction (planned_s, confirmed_s, ...)
Writes  steps.csv in the same folder (and prints it): the totals over all gateways: readings offered
        and stored per second, the waiting time (planned send time to block) over all transactions,
        lost transactions, and the lowest and highest share one gateway got.
"""
import argparse
import csv
import glob
import re
from pathlib import Path
from typing import List

# columns of steps.csv (the "%" format in step_row() must match this order)
HEADER = ("total_readings_s_target,gateways,batch,offered_readings_s,delivered_readings_s,"
          "confirmed_rate_readings_s,delivered_min_gw,delivered_max_gw,lost,rejections,"
          "lat_p50,lat_p90,lat_p99,lat_max,mempool_max_bytes")


def totals_in(folder: Path) -> List[int]:
    """The total rates (readings per second) that have gateway files in the folder, ascending."""
    files = glob.glob(str(folder / "steps-R*-gw*.csv"))
    return sorted({int(re.search(r"steps-R(\d+)-", f).group(1)) for f in files})


def quantile(sorted_values: List[float], p: float) -> float:
    """Value at fraction p of an ascending list (NaN if the list is empty)."""
    if not sorted_values:
        return float("nan")
    return sorted_values[min(len(sorted_values) - 1, int(p * len(sorted_values)))]


def step_row(folder: Path, total: int) -> str:
    """The steps.csv line of one total rate, added up over all gateways."""
    rows = []                                    # the summary row of every gateway
    for f in sorted(glob.glob(str(folder / f"steps-R{total}-gw*.csv"))):
        rows.append(list(csv.DictReader(open(f)))[-1])
    lat: List[float] = []                        # waiting time of every confirmed transaction
    conf: List[float] = []                       # confirmation time of every confirmed transaction
    for f in sorted(glob.glob(str(folder / f"txs-R{total}-gw*.csv"))):
        for r in csv.DictReader(open(f)):
            if r["confirmed_s"]:
                lat.append(float(r["confirmed_s"]) - float(r["planned_s"]))
                conf.append(float(r["confirmed_s"]))
    lat.sort()
    conf.sort()
    # readings stored per second from the first to the last confirmation: over a long step this is the sustained rate
    rate = (len(conf) - 1) * int(rows[0]["batch"]) / (conf[-1] - conf[0]) if len(conf) > 1 else float("nan")
    delivered = [float(r["delivered_readings_s"]) for r in rows]
    return "%d,%d,%s,%.1f,%.1f,%.1f,%.1f,%.1f,%d,%d,%.2f,%.2f,%.2f,%.2f,%d" % (
        total, len(rows), rows[0]["batch"], sum(float(r["offered_readings_s"]) for r in rows), sum(delivered), rate,
        min(delivered), max(delivered), sum(int(r["lost"]) for r in rows), sum(int(r["rejections"]) for r in rows),
        quantile(lat, 0.5), quantile(lat, 0.9), quantile(lat, 0.99), lat[-1] if lat else float("nan"),
        max(int(r["mempool_max_bytes"]) for r in rows))


def main() -> None:
    parser = argparse.ArgumentParser(description="Add up the gateways of one gateways.sh run; writes steps.csv.")
    parser.add_argument("folder", type=Path, help="result folder of gateways.sh (results/gateways-<date-time>)")
    folder = parser.parse_args().folder
    out = [HEADER] + [step_row(folder, total) for total in totals_in(folder)]
    (folder / "steps.csv").write_text("\n".join(out) + "\n")
    print("\n".join(out))


if __name__ == "__main__":
    main()
