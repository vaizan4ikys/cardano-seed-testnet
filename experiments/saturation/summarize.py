#!/usr/bin/env python3
"""Table of a saturation series (made by saturate.sh).

Usage:
    python3 summarize.py results/saturation-<date-time>

Reads <folder>/steps.csv (one row per step). Prints one table row per step: offered and delivered
readings per second, latency (planned submit time to block), transactions still waiting at the end of
the submitting, rejections of the mempool, and the best delivered rate per batch size.
Also writes the same text to <folder>/summary.txt.
"""
import argparse
import csv
from pathlib import Path
from typing import Dict, List

HEADER_1 = (f"{'batch':>5} {'tx B':>6} {'target':>7} {'offered':>8} | {'offered':>8} {'delivered':>9} | "
            f"{'p50':>6} {'p90':>6} {'p99':>6} | {'backlog':>7} {'lost':>5} {'rejects':>7} {'mempool KB':>10}")
HEADER_2 = (f"{'':>5} {'':>6} {'tx/s':>7} {'tx/s':>8} | {'read/s':>8} {'read/s':>9} | "
            f"{'s':>6} {'s':>6} {'s':>6} | {'txs':>7} {'txs':>5} {'':>7} {'':>10}")
NOTE = ("(offered below the target = the generator could not keep up; delivered counts what was in a block "
        "before the submitting ended, so it is a little low at short durations)")


def step_line(r: Dict[str, str]) -> str:
    """One table row for one row of steps.csv."""
    return (f"{int(r['batch']):>5} {r['tx_bytes']:>6} {r['rate_target_tx_s']:>7} {r['offered_tx_s']:>8} | "
            f"{r['offered_readings_s']:>8} {r['delivered_readings_s']:>9} | "
            f"{r['lat_p50']:>6} {r['lat_p90']:>6} {r['lat_p99']:>6} | "
            f"{r['backlog_end']:>7} {r['lost']:>5} {r['rejections']:>7} {int(r['mempool_max_bytes']) // 1000:>10}")


def build_table(rows: List[Dict[str, str]]) -> str:
    """The whole text: two header lines, one line per step, the best rate per batch size, a note."""
    out = [HEADER_1, HEADER_2]
    best: Dict[int, float] = {}                      # batch size -> highest delivered readings per second
    for r in rows:
        b = int(r["batch"])
        best[b] = max(best.get(b, 0), float(r["delivered_readings_s"]))
        out.append(step_line(r))
    out.append("")
    out.append("best delivered readings/s per batch size: " + ", ".join(f"{b}: {v:.0f}" for b, v in sorted(best.items())))
    out.append(NOTE)
    return "\n".join(out)


def main() -> None:
    parser = argparse.ArgumentParser(description="Table of a saturation series; also writes summary.txt.")
    parser.add_argument("folder", type=Path, help="result folder of saturate.sh (results/saturation-<date-time>)")
    folder = parser.parse_args().folder
    with open(folder / "steps.csv") as f:
        rows = list(csv.DictReader(f))
    text = build_table(rows)
    print(text)
    (folder / "summary.txt").write_text(text + "\n")


if __name__ == "__main__":
    main()
