#!/usr/bin/env python3
"""Medians and percentiles of one run-all.sh result folder.

Usage:
    summarize.py results/<date-time>

Reads sync.csv, tx.csv, propagation.csv and blockrate.txt from that folder and prints four tables:
join time, transaction latency, block propagation and block rate, one row per delay / loss setting.

Hop 1, hop 1B and hop 2 are the machines VM2, VM3 and VM4 of scripts/config.sh (seedvm2, seedvm3 and
seedvm4 in our lab). The CSV files hold the machine names, so set the environment variables HOP1, HOP1B
and HOP2 to the values run-all.sh used, if they were not the defaults.
"""
import csv
import os
import statistics
import sys
from collections import defaultdict
from typing import Dict, List

# Machine names of the joiners as they appear in the CSV files of run-all.sh.
HOP1 = os.environ.get('HOP1', 'seedvm2')      # dials the pools
HOP1B = os.environ.get('HOP1B', 'seedvm3')    # second joiner that dials the pools (parallel test only)
HOP2 = os.environ.get('HOP2', 'seedvm4')      # dials hop 1

# Column titles of the two joiners.
TITLE1 = HOP1 + ' (hop1)'
TITLE2 = HOP2 + ' (hop2)'


def percentile(values: List[float], p: float) -> float:
    """The p-quantile (0..1) of a list, by rounding the position in the sorted list."""
    v = sorted(values)
    return v[min(len(v) - 1, int(round(p * (len(v) - 1))))]


def read_csv(folder: str, name: str) -> List[Dict[str, str]]:
    """Rows of <folder>/<name> as dicts."""
    return list(csv.DictReader(open(f'{folder}/{name}')))


def join_times(folder: str) -> None:
    """Table 1: median join time per delay, loss and joiner (single mode), and the parallel test."""
    print("JOIN TIME, seconds (median of reps; start-up part ~0.5 s)   single mode")
    g = defaultdict(list)
    for r in read_csv(folder, 'sync.csv'):
        if r['mode'] == 'single' and r['seconds'] != 'NA':
            g[(int(r['delay_ms']), int(r['loss_pct']), r['node'])].append(float(r['seconds']))
    print(f"{'delay':>6} {'loss':>5} | {TITLE1:>15} {TITLE2:>15}")
    for dl in sorted({k[0] for k in g}):
        for ls in sorted({k[1] for k in g}):
            a, b = g.get((dl, ls, HOP1), []), g.get((dl, ls, HOP2), [])
            if a or b:
                # a join that did not finish in 900 s is NA, so it is not in the lists
                def cell(v):
                    return f"{statistics.median(v):.1f}" if v else "failed"
                print(f"{dl:>5}ms {ls:>4}% | {cell(a):>15} {cell(b):>15}   (n={len(a)}, {len(b)})")

    # three joiners at the same time, against hop 1 alone (both without delay)
    par = defaultdict(list)
    one = []
    for r in read_csv(folder, 'sync.csv'):
        if r['mode'] == 'parallel' and r['seconds'] != 'NA':
            par[r['node']].append(float(r['seconds']))
        if (r['mode'] == 'single' and r['seconds'] != 'NA' and r['delay_ms'] == '0' and r['loss_pct'] == '0'
                and r['node'] == HOP1):
            one.append(float(r['seconds']))
    if par.get(HOP1) and one:
        print("parallel (0 ms): %s %.1f s, %s %.1f s;  alone: %s %.1f s"
              % (HOP1, statistics.median(par[HOP1]), HOP1B, statistics.median(par[HOP1B]),
                 HOP1, statistics.median(one)))


def transaction_latency(folder: str) -> None:
    """Table 2: transaction latency (block: median / p90, mempool: median) and the overall numbers."""
    print("\nTRANSACTION LATENCY, seconds: until the block (median / p90), and until the pool's mempool (median)")
    g = defaultdict(list)
    mem = defaultdict(list)
    for r in read_csv(folder, 'tx.csv'):
        key = (int(r['delay_ms']), int(r['loss_pct']), r['node'])
        g[key].append(float(r['seconds']))
        if r.get('mempool_seconds', 'NA') != 'NA':
            mem[key].append(float(r['mempool_seconds']))
    print(f"{'delay':>6} {'loss':>5} | {TITLE1:>28} {TITLE2:>28}")
    for dl in sorted({k[0] for k in g}):
        for ls in sorted({k[1] for k in g}):
            c = []
            for n in (HOP1, HOP2):
                v = g.get((dl, ls, n), [])
                m = mem.get((dl, ls, n), [])
                cell = f"{statistics.median(v):.1f} / {percentile(v, 0.9):.1f}" if v else '-'
                if m:
                    cell += f"  mempool {statistics.median(m):.2f}"
                c.append(cell + (f"  (n={len(v)})" if v else ''))
            print(f"{dl:>5}ms {ls:>4}% | {c[0]:>28} {c[1]:>28}")
    allv = [float(r['seconds']) for r in read_csv(folder, 'tx.csv')]
    print("all transactions: median %.1f s, mean %.1f s, p90 %.1f s, max %.1f s (n=%d)"
          % (statistics.median(allv), statistics.mean(allv), percentile(allv, 0.9), max(allv), len(allv)))


def block_propagation(folder: str) -> None:
    """Table 3: block propagation delay behind the forging pool, median / p95 and number of blocks."""
    print("\nBLOCK PROPAGATION, ms behind the forging pool: median / p95   (blocks)")
    g = {}
    for r in read_csv(folder, 'propagation.csv'):
        g[(int(r['delay_ms']), int(r['loss_pct']), r['node'])] = r
    print(f"{'delay':>6} {'loss':>5} | {'pool2':>14} {TITLE1:>22} {TITLE2:>22}")
    for dl in sorted({k[0] for k in g}):
        for ls in sorted({k[1] for k in g}):
            c = []
            for n in ('pool2', HOP1, HOP2):
                r = g.get((dl, ls, n))
                c.append(f"{r['median_ms']} / {r['p95_ms']}  ({r['blocks']})" if r else '-')
            print(f"{dl:>5}ms {ls:>4}% | {c[0]:>14} {c[1]:>22} {c[2]:>22}")


def block_rate(folder: str) -> None:
    """Table 4: the block rate lines that run-all.sh wrote into blockrate.txt."""
    print("\nBLOCK RATE (theory 12/min):")
    for line in open(f'{folder}/blockrate.txt'):
        if line.startswith('delay'):
            print(' ', line.strip())


def main() -> None:
    """summarize.py <results folder>: print the four tables."""
    folder = sys.argv[1]
    join_times(folder)
    transaction_latency(folder)
    block_propagation(folder)
    block_rate(folder)


if __name__ == '__main__':
    main()
