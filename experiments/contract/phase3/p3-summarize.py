#!/usr/bin/env python3
"""Phase 3 summary: steps.csv (+ costs.csv) -> tables per (variant, rate): median and range over the repetitions, and for S and R
the difference to P with the two rules of PHASE3-PLAN.md (larger than the range of the P repetitions; same sign in at least
5 of 6 repetitions). The warm-up step and steps marked invalid are left out.
   python3 p3-summarize.py results/steps.csv [results/costs.csv]"""
import csv, statistics, sys
from collections import defaultdict

METRICS = [("delivered_readings_s", "readings/s delivered in the window"), ("lat_p50", "latency p50 (s)"), ("lat_p90", "latency p90 (s)"),
           ("txs_block_med", "transactions per block (median)"), ("bytes_block_med", "bytes per block (median)"),
           ("lat_blk_p50", "latency p50 (blocks)"), ("lat_blk_p90", "latency p90 (blocks)"), ("backlog_end", "backlog at end"),
           ("lost", "lost"), ("rejections", "rejections"), ("mempool_max_bytes", "mempool max (bytes)"), ("blocks_window", "blocks in window")]

def num(x):
    try: return float(x)
    except (TypeError, ValueError): return None

def main():
    rows = list(csv.DictReader(open(sys.argv[1])))
    if len(sys.argv) > 2:
        print("PART A: one transaction (costs.csv)")
        for r in csv.DictReader(open(sys.argv[2])):
            print("  %-2s N=%-3s size %5s B  fee %6s  measured %11s steps %8s mem  declared %s/%s" % (
                r["variant"], r["registry_keys"], r["tx_bytes"], r["fee_lovelace"], r["measured_steps"], r["measured_mem"], r["declared_steps"], r["declared_mem"]))
        print()
    data = defaultdict(dict)                       # (variant, rate) -> rep -> row
    skipped = []
    for r in rows:
        if r["id"] == "warmup": continue
        if r.get("invalid_reason"): skipped.append((r["id"], r["invalid_reason"]))
        data[(r["variant"], float(r["rate_tx_s"]))][int(r["rep"])] = r
    rates = sorted({k[1] for k in data})
    print("PART B: load test, 100 readings per transaction; median [min .. max] over repetitions (n = number of valid repetitions)")
    for rate in rates:
        print("\nOffered %.1f tx/s" % rate)
        for v in "PSR":
            d = {rep: r for rep, r in data.get((v, rate), {}).items() if not r.get("invalid_reason")}
            if not d: continue
            print("  variant %s (n=%d, tx size %s B)" % (v, len(d), next(iter(d.values()))["tx_bytes"]))
            for key, label in METRICS:
                xs = [num(r[key]) for r in d.values() if num(r.get(key)) is not None]
                if xs: print("    %-38s %10.2f  [%.2f .. %.2f]" % (label, statistics.median(xs), min(xs), max(xs)))
        # difference to P
        base = {rep: r for rep, r in data.get(("P", rate), {}).items() if not r.get("invalid_reason")}
        for v in "SR":
            d = {rep: r for rep, r in data.get((v, rate), {}).items() if not r.get("invalid_reason")}
            common = sorted(set(base) & set(d))
            if len(common) < 3: continue
            print("  %s minus P (paired by repetition, n=%d):" % (v, len(common)))
            for key, label in METRICS[:6]:
                diffs = [num(d[k][key]) - num(base[k][key]) for k in common if num(d[k][key]) is not None and num(base[k][key]) is not None]
                if not diffs: continue
                pvals = [num(base[k][key]) for k in common if num(base[k][key]) is not None]
                prange = max(pvals) - min(pvals)
                med = statistics.median(diffs)
                same = max(sum(1 for x in diffs if x > 0), sum(1 for x in diffs if x < 0))
                real = abs(med) > prange and same >= len(diffs) - 1 and same >= 5 * len(diffs) // 6
                print("    %-38s median diff %9.2f   (range of P: %.2f; same sign %d of %d)  -> %s" % (label, med, prange, same, len(diffs), "REAL difference" if real else "within the noise"))
    if skipped:
        print("\nNot used (invalid):", "; ".join("%s (%s)" % s for s in skipped))

main()
