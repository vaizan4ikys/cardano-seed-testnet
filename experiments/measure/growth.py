#!/usr/bin/env python3
"""Join time, transaction latency and propagation against the size of a growing chain.

    growth.py results/growth-<date-time>

Reads the folder made by checkpoints.sh: chain.csv and one cp-NN/ folder per checkpoint. Prints
one row per checkpoint and writes the same table to growth.csv in that folder.

    chain MB / KB per block   size of the chain on pool 1 (its immutable database; the volatile part holds
                              recent blocks twice and is cleaned up in steps), and its growth per block
                              since the last checkpoint (how full the blocks are; the limit is 64 KB)
    blocks/min                blocks added to the chain per minute since the last checkpoint
    join s (ready+sync)       a fresh node on seedvm2 with no added delay: total seconds, of which
                              start-up (ready) and copying the chain (sync)
    copy MB/s                 chain data copied / sync seconds; the data is the chain size at the
                              checkpoint scaled by (blocks at the join / blocks at the checkpoint)
    join 100ms                the same join with 100 ms added delay
    3 joins                   seedvm2, seedvm3 and seedvm4 joining at once: seconds of the slowest
    tx block / mempool        median seconds from submit on seedvm2 until the block / the pool's mempool
    propagation               median ms for a block to reach seedvm2 (1 hop) and seedvm4 (2 hops)
"""
import csv
import os
import statistics
import sys
from datetime import datetime

folder = sys.argv[1]
chain = list(csv.DictReader(open(os.path.join(folder, 'chain.csv'))))


def rows(checkpoint, name):
    path = os.path.join(folder, checkpoint, name)
    return list(csv.DictReader(open(path))) if os.path.exists(path) else []


def median(values):
    return statistics.median(values) if values else float('nan')


header = ['checkpoint', 'hours', 'block', 'chain_MB', 'KB_per_block', 'blocks_per_min', 'join_s', 'ready_s', 'sync_s',
          'copy_MB_per_s', 'join_100ms_s', 'three_joins_s', 'tx_block_s', 'tx_mempool_s', 'prop_hop1_ms', 'prop_hop2_ms']
table = []
first_time = previous = None
for c in chain:
    when = datetime.fromisoformat(c['time_utc'].replace('Z', '+00:00'))
    block = int(c['block'])
    chain_kb = int(c['immutable_kb']) if c.get('immutable_kb') else None   # empty for the first, older row
    first_time = first_time or when
    kb_per_block = blocks_per_min = float('nan')
    if previous:
        seconds = (when - previous[0]).total_seconds()
        if block > previous[1]:
            if chain_kb is not None and previous[2] is not None:
                kb_per_block = (chain_kb - previous[2]) / (block - previous[1])
            blocks_per_min = (block - previous[1]) / seconds * 60
    previous = (when, block, chain_kb)

    cp = c['checkpoint']
    sync = rows(cp, 'sync.csv')
    single = [r for r in sync if r['mode'] == 'single' and r['node'] == 'seedvm2']
    at = lambda delay: [r for r in single if r['delay_ms'] == delay]
    join_s = median([float(r['seconds']) for r in at('0')])
    ready_s = median([float(r['ready_seconds']) for r in at('0')])
    sync_s = median([float(r['sync_seconds']) for r in at('0')])
    joined_blocks = median([int(r['blocks']) for r in at('0')])
    copied_mb = chain_kb / 1024 * joined_blocks / block if chain_kb else float('nan')
    join100_s = median([float(r['seconds']) for r in at('100')])
    reps = {}
    for r in sync:
        if r['mode'] == 'parallel':
            reps[r['rep']] = max(reps.get(r['rep'], 0), float(r['seconds']))
    tx = [r for r in rows(cp, 'tx.csv') if r['delay_ms'] == '0' and r['node'] == 'seedvm2']
    prop = {r['node']: float(r['median_ms']) for r in rows(cp, 'propagation.csv') if r['delay_ms'] == '0'}
    table.append([cp, (when - first_time).total_seconds() / 3600, block, chain_kb / 1024 if chain_kb else float('nan'), kb_per_block, blocks_per_min,
                  join_s, ready_s, sync_s, copied_mb / sync_s if sync_s > 0 else float('nan'), join100_s,
                  median(list(reps.values())),
                  median([float(r['seconds']) for r in tx]),
                  median([float(r['mempool_seconds']) for r in tx if r['mempool_seconds'] != 'NA']),
                  prop.get('seedvm2', float('nan')), prop.get('seedvm4', float('nan'))])

with open(os.path.join(folder, 'growth.csv'), 'w', newline='') as f:
    writer = csv.writer(f)
    writer.writerow(header)
    writer.writerows([[f'{v:.2f}' if isinstance(v, float) else v for v in row] for row in table])

print(f"{'cp':<6}{'hours':>6}{'block':>7}{'chainMB':>8}{'KB/blk':>7}{'blk/min':>8} |{'join s':>7}{'ready':>6}{'sync':>6}"
      f"{'MB/s':>6} |{'+100ms':>7}{'3 joins':>8} |{'tx blk':>7}{'mempool':>8} |{'hop1 ms':>8}{'hop2 ms':>8}")
for r in table:
    print(f"{r[0]:<6}{r[1]:>6.1f}{r[2]:>7}{r[3]:>8.1f}{r[4]:>7.1f}{r[5]:>8.1f} |{r[6]:>7.1f}{r[7]:>6.1f}{r[8]:>6.1f}"
          f"{r[9]:>6.1f} |{r[10]:>7.1f}{r[11]:>8.1f} |{r[12]:>7.1f}{r[13]:>8.2f} |{r[14]:>8.0f}{r[15]:>8.0f}")
