#!/usr/bin/env python3
"""Phase 3 summary: steps.csv (+ costs.csv) -> tables per (variant, rate).

For every (variant, rate) it prints the median and the range over the repetitions. For S and R it also prints the
difference to P with the two rules of PHASE3-PLAN.md: the difference must be larger than the range of the P
repetitions, and must have the same sign in at least 5 of 6 repetitions. The warm-up step and the steps marked
invalid are left out.

Run:    python3 p3-summarize.py results/steps.csv [results/costs.csv]
Reads:  steps.csv (one row per step, written by p3-run.sh) and optionally costs.csv (written by p3-costs.sh).
Writes: the tables on stdout.
"""
import argparse
import csv
import statistics
import sys
from collections import defaultdict
from typing import Optional

# The columns of steps.csv that are summarized: (column name, label in the table).
METRICS = [
    ("delivered_readings_s", "readings/s delivered in the window"),
    ("lat_p50", "latency p50 (s)"),
    ("lat_p90", "latency p90 (s)"),
    ("txs_block_med", "transactions per block (median)"),
    ("bytes_block_med", "bytes per block (median)"),
    ("lat_blk_p50", "latency p50 (blocks)"),
    ("lat_blk_p90", "latency p90 (blocks)"),
    ("backlog_end", "backlog at end"),
    ("lost", "lost"),
    ("rejections", "rejections"),
    ("mempool_max_bytes", "mempool max (bytes)"),
    ("blocks_window", "blocks in window"),
]
# The "S minus P" comparison uses only the first metrics (the latency and block numbers).
N_COMPARED_METRICS = 6
MIN_COMMON_REPETITIONS = 3      # fewer paired repetitions: no comparison


def num(x) -> Optional[float]:
    """The value as a float, or None when it is empty or not a number."""
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def print_costs(path: str) -> None:
    """PART A: the cost of one transaction per variant and registry size (costs.csv)."""
    print("PART A: one transaction (costs.csv)")
    for r in csv.DictReader(open(path)):
        print("  %-2s N=%-3s size %5s B  fee %6s  measured %11s steps %8s mem  declared %s/%s" % (
            r["variant"], r["registry_keys"], r["tx_bytes"], r["fee_lovelace"],
            r["measured_steps"], r["measured_mem"], r["declared_steps"], r["declared_mem"]))
    print()


def valid_steps(data: dict, variant: str, rate: float) -> dict:
    """The repetitions of one (variant, rate) that are not marked invalid: repetition -> row."""
    return {rep: r for rep, r in data.get((variant, rate), {}).items() if not r.get("invalid_reason")}


def print_difference(data: dict, variant: str, rate: float) -> None:
    """Prints 'variant minus P', paired by repetition, with the two rules for a REAL difference."""
    base = valid_steps(data, "P", rate)
    d = valid_steps(data, variant, rate)
    common = sorted(set(base) & set(d))
    if len(common) < MIN_COMMON_REPETITIONS:
        return
    print("  %s minus P (paired by repetition, n=%d):" % (variant, len(common)))
    for key, label in METRICS[:N_COMPARED_METRICS]:
        diffs = [num(d[k][key]) - num(base[k][key]) for k in common
                 if num(d[k][key]) is not None and num(base[k][key]) is not None]
        if not diffs:
            continue
        pvals = [num(base[k][key]) for k in common if num(base[k][key]) is not None]
        prange = max(pvals) - min(pvals)
        med = statistics.median(diffs)
        same = max(sum(1 for x in diffs if x > 0), sum(1 for x in diffs if x < 0))
        real = abs(med) > prange and same >= len(diffs) - 1 and same >= 5 * len(diffs) // 6
        print("    %-38s median diff %9.2f   (range of P: %.2f; same sign %d of %d)  -> %s" % (
            label, med, prange, same, len(diffs), "REAL difference" if real else "within the noise"))


def main(argv: Optional[list] = None) -> None:
    parser = argparse.ArgumentParser(description="Summary tables of the Phase 3 load test.")
    parser.add_argument("steps_csv", help="results/steps.csv written by p3-run.sh")
    parser.add_argument("costs_csv", nargs="?", help="optional results/costs.csv written by p3-costs.sh (PART A)")
    args = parser.parse_args(argv)

    rows = list(csv.DictReader(open(args.steps_csv)))
    if args.costs_csv:
        print_costs(args.costs_csv)

    data = defaultdict(dict)                       # (variant, rate) -> repetition -> row
    skipped = []
    for r in rows:
        if r["id"] == "warmup":
            continue
        if r.get("invalid_reason"):
            skipped.append((r["id"], r["invalid_reason"]))
        data[(r["variant"], float(r["rate_tx_s"]))][int(r["rep"])] = r
    rates = sorted({k[1] for k in data})

    print("PART B: load test, 100 readings per transaction; "
          "median [min .. max] over repetitions (n = number of valid repetitions)")
    for rate in rates:
        print("\nOffered %.1f tx/s" % rate)
        for v in "PSR":
            d = valid_steps(data, v, rate)
            if not d:
                continue
            print("  variant %s (n=%d, tx size %s B)" % (v, len(d), next(iter(d.values()))["tx_bytes"]))
            for key, label in METRICS:
                xs = [num(r[key]) for r in d.values() if num(r.get(key)) is not None]
                if xs:
                    print("    %-38s %10.2f  [%.2f .. %.2f]" % (label, statistics.median(xs), min(xs), max(xs)))
        for v in "SR":
            print_difference(data, v, rate)
    if skipped:
        print("\nNot used (invalid):", "; ".join("%s (%s)" % s for s in skipped))


if __name__ == "__main__":
    main()
