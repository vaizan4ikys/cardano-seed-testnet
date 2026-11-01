#!/usr/bin/env python3
"""Medians and percentiles of one run-all.sh result folder.

    summarize.py results/<date-time>
"""
import csv, statistics, sys
from collections import defaultdict
d = sys.argv[1]
def q(v, p):
    v = sorted(v); return v[min(len(v)-1, int(round(p*(len(v)-1))))]
def rows(f): return list(csv.DictReader(open(f'{d}/{f}')))

print("JOIN TIME, seconds (median of reps; start-up part ~0.5 s)   single mode")
g = defaultdict(list)
for r in rows('sync.csv'):
    if r['mode'] == 'single' and r['seconds'] != 'NA': g[(int(r['delay_ms']), int(r['loss_pct']), r['node'])].append(float(r['seconds']))
print(f"{'delay':>6} {'loss':>5} | {'seedvm2 (hop1)':>15} {'seedvm4 (hop2)':>15}")
for dl in sorted({k[0] for k in g}):
    for ls in sorted({k[1] for k in g}):
        a, b = g.get((dl, ls, 'seedvm2'), []), g.get((dl, ls, 'seedvm4'), [])
        if a or b:
            cell = lambda v: f"{statistics.median(v):.1f}" if v else "failed"       # a join that did not finish in 900 s is NA
            print(f"{dl:>5}ms {ls:>4}% | {cell(a):>15} {cell(b):>15}   (n={len(a)}, {len(b)})")
par = defaultdict(list); one = []
for r in rows('sync.csv'):
    if r['mode'] == 'parallel' and r['seconds'] != 'NA': par[r['node']].append(float(r['seconds']))
    if r['mode'] == 'single' and r['seconds'] != 'NA' and r['delay_ms'] == '0' and r['loss_pct'] == '0' and r['node'] == 'seedvm2': one.append(float(r['seconds']))
if par.get("seedvm2") and one: print("parallel (0 ms): seedvm2 %.1f s, seedvm3 %.1f s;  alone: seedvm2 %.1f s" % (statistics.median(par['seedvm2']), statistics.median(par['seedvm3']), statistics.median(one)))

print("\nTRANSACTION LATENCY, seconds: until the block (median / p90), and until the pool's mempool (median)")
g = defaultdict(list); mem = defaultdict(list)
for r in rows('tx.csv'):
    key = (int(r['delay_ms']), int(r['loss_pct']), r['node'])
    g[key].append(float(r['seconds']))
    if r.get('mempool_seconds', 'NA') != 'NA': mem[key].append(float(r['mempool_seconds']))
print(f"{'delay':>6} {'loss':>5} | {'seedvm2 (hop1)':>28} {'seedvm4 (hop2)':>28}")
for dl in sorted({k[0] for k in g}):
    for ls in sorted({k[1] for k in g}):
        c = []
        for n in ('seedvm2', 'seedvm4'):
            v = g.get((dl, ls, n), []); m = mem.get((dl, ls, n), [])
            cell = f"{statistics.median(v):.1f} / {q(v,0.9):.1f}" if v else '-'
            if m: cell += f"  mempool {statistics.median(m):.2f}"
            c.append(cell + (f"  (n={len(v)})" if v else ''))
        print(f"{dl:>5}ms {ls:>4}% | {c[0]:>28} {c[1]:>28}")
allv = [float(r['seconds']) for r in rows('tx.csv')]
print("all transactions: median %.1f s, mean %.1f s, p90 %.1f s, max %.1f s (n=%d)" % (statistics.median(allv), statistics.mean(allv), q(allv,0.9), max(allv), len(allv)))

print("\nBLOCK PROPAGATION, ms behind the forging pool: median / p95   (blocks)")
g = {}
for r in rows('propagation.csv'): g[(int(r['delay_ms']), int(r['loss_pct']), r['node'])] = r
print(f"{'delay':>6} {'loss':>5} | {'pool2':>14} {'seedvm2 (hop1)':>22} {'seedvm4 (hop2)':>22}")
for dl in sorted({k[0] for k in g}):
    for ls in sorted({k[1] for k in g}):
        c = []
        for n in ('pool2', 'seedvm2', 'seedvm4'):
            r = g.get((dl, ls, n))
            c.append(f"{r['median_ms']} / {r['p95_ms']}  ({r['blocks']})" if r else '-')
        print(f"{dl:>5}ms {ls:>4}% | {c[0]:>14} {c[1]:>22} {c[2]:>22}")

print("\nBLOCK RATE (theory 12/min):")
for l in open(f'{d}/blockrate.txt'):
    if l.startswith('delay'): print(' ', l.strip())
