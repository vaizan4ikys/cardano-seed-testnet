#!/usr/bin/env python3
"""Table of a saturation series: summarize.py results/saturation-<date-time>

Per batch size: offered and delivered readings per second, latency (planned submit time to block),
transactions still waiting at the end of the submitting, rejections of the mempool, and the best
delivered rate. Also writes summary.txt into the folder."""
import csv
import sys
from pathlib import Path


def main():
    folder = Path(sys.argv[1])
    rows = list(csv.DictReader(open(folder / "steps.csv")))
    out = []
    out.append(f"{'batch':>5} {'tx B':>6} {'target':>7} {'offered':>8} | {'offered':>8} {'delivered':>9} | "
               f"{'p50':>6} {'p90':>6} {'p99':>6} | {'backlog':>7} {'lost':>5} {'rejects':>7} {'mempool KB':>10}")
    out.append(f"{'':>5} {'':>6} {'tx/s':>7} {'tx/s':>8} | {'read/s':>8} {'read/s':>9} | "
               f"{'s':>6} {'s':>6} {'s':>6} | {'txs':>7} {'txs':>5} {'':>7} {'':>10}")
    best = {}
    for r in rows:
        b = int(r["batch"])
        d = float(r["delivered_readings_s"])
        best[b] = max(best.get(b, 0), d)
        out.append(f"{b:>5} {r['tx_bytes']:>6} {r['rate_target_tx_s']:>7} {r['offered_tx_s']:>8} | "
                   f"{r['offered_readings_s']:>8} {r['delivered_readings_s']:>9} | "
                   f"{r['lat_p50']:>6} {r['lat_p90']:>6} {r['lat_p99']:>6} | "
                   f"{r['backlog_end']:>7} {r['lost']:>5} {r['rejections']:>7} {int(r['mempool_max_bytes']) // 1000:>10}")
    out.append("")
    out.append("best delivered readings/s per batch size: " + ", ".join(f"{b}: {v:.0f}" for b, v in sorted(best.items())))
    out.append("(offered below the target = the generator could not keep up; delivered counts what was in a block "
               "before the submitting ended, so it is a little low at short durations)")
    text = "\n".join(out)
    print(text)
    (folder / "summary.txt").write_text(text + "\n")


if __name__ == "__main__":
    main()
