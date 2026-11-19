#!/usr/bin/env python3
"""Join time, transaction latency and propagation against the size of a growing chain.

Usage:
    growth.py results/growth-<date-time>

Reads the folder made by checkpoints.sh: chain.csv and one cp-NN/ folder per checkpoint (with the
sync.csv, tx.csv and propagation.csv of run-all.sh). Prints one row per checkpoint and writes the
same table to growth.csv in that folder.

    chain MB / KB per block   size of the chain on pool 1 (its immutable database; the volatile part holds
                              recent blocks twice and is cleaned up in steps), and its growth per block
                              since the last checkpoint (how full the blocks are; the limit is 64 KB)
    blocks/min                blocks added to the chain per minute since the last checkpoint
    join s (ready+sync)       a fresh node on hop 1 with no added delay: total seconds, of which
                              start-up (ready) and copying the chain (sync)
    copy MB/s                 chain data copied / sync seconds; the data is the chain size at the
                              checkpoint scaled by (blocks at the join / blocks at the checkpoint)
    join 100ms                the same join with 100 ms added delay
    3 joins                   hop 1, hop 1B and hop 2 joining at once: seconds of the slowest
    tx block / mempool        median seconds from submit on hop 1 until the block / the pool's mempool
    propagation               median ms for a block to reach hop 1 (1 hop) and hop 2 (2 hops)

Hop 1 and hop 2 are the machines VM2 and VM4 of scripts/config.sh (seedvm2 and seedvm4 in our lab).
The names in the CSV files are the machine names, so set the environment variables HOP1 and HOP2 to the
same values that run-all.sh used, if they were not the defaults.
"""
import csv
import os
import statistics
import sys
from datetime import datetime
from typing import Dict, List, Optional

# Machine names of hop 1 and hop 2 as they appear in the CSV files of run-all.sh.
HOP1 = os.environ.get('HOP1', 'seedvm2')
HOP2 = os.environ.get('HOP2', 'seedvm4')

# Columns of growth.csv (and of the printed table, which shows a subset with shorter names).
HEADER = ['checkpoint', 'hours', 'block', 'chain_MB', 'KB_per_block', 'blocks_per_min', 'join_s', 'ready_s', 'sync_s',
          'copy_MB_per_s', 'join_100ms_s', 'three_joins_s', 'tx_block_s', 'tx_mempool_s', 'prop_hop1_ms', 'prop_hop2_ms']

NAN = float('nan')


def read_rows(folder: str, checkpoint: str, name: str) -> List[Dict[str, str]]:
    """Rows of <folder>/<checkpoint>/<name> as dicts, or [] if that file does not exist."""
    path = os.path.join(folder, checkpoint, name)
    return list(csv.DictReader(open(path))) if os.path.exists(path) else []


def median(values: list) -> float:
    """Median of a list, NaN if it is empty."""
    return statistics.median(values) if values else NAN


def checkpoint_row(folder: str, chain_row: Dict[str, str], first_time: datetime, previous: Optional[tuple]) -> list:
    """One table row for a checkpoint; `previous` is (time, block, chain kB) of the checkpoint before it."""
    when = datetime.fromisoformat(chain_row['time_utc'].replace('Z', '+00:00'))
    block = int(chain_row['block'])
    chain_kb = int(chain_row['immutable_kb']) if chain_row.get('immutable_kb') else None   # empty in the first, older row

    kb_per_block = blocks_per_min = NAN
    if previous:
        seconds = (when - previous[0]).total_seconds()
        if block > previous[1]:
            if chain_kb is not None and previous[2] is not None:
                kb_per_block = (chain_kb - previous[2]) / (block - previous[1])
            blocks_per_min = (block - previous[1]) / seconds * 60

    cp = chain_row['checkpoint']

    # joins of hop 1 (alone, without and with 100 ms delay)
    sync = read_rows(folder, cp, 'sync.csv')
    single = [r for r in sync if r['mode'] == 'single' and r['node'] == HOP1]

    def at(delay: str) -> list:
        return [r for r in single if r['delay_ms'] == delay]

    join_s = median([float(r['seconds']) for r in at('0')])
    ready_s = median([float(r['ready_seconds']) for r in at('0')])
    sync_s = median([float(r['sync_seconds']) for r in at('0')])
    joined_blocks = median([int(r['blocks']) for r in at('0')])
    copied_mb = chain_kb / 1024 * joined_blocks / block if chain_kb else NAN
    join100_s = median([float(r['seconds']) for r in at('100')])

    # three joins at once: the time of the slowest, per repetition
    slowest = {}
    for r in sync:
        if r['mode'] == 'parallel':
            slowest[r['rep']] = max(slowest.get(r['rep'], 0), float(r['seconds']))

    # transactions and propagation at delay 0
    tx = [r for r in read_rows(folder, cp, 'tx.csv') if r['delay_ms'] == '0' and r['node'] == HOP1]
    prop = {r['node']: float(r['median_ms']) for r in read_rows(folder, cp, 'propagation.csv') if r['delay_ms'] == '0'}

    return [cp, (when - first_time).total_seconds() / 3600, block, chain_kb / 1024 if chain_kb else NAN,
            kb_per_block, blocks_per_min,
            join_s, ready_s, sync_s, copied_mb / sync_s if sync_s > 0 else NAN, join100_s,
            median(list(slowest.values())),
            median([float(r['seconds']) for r in tx]),
            median([float(r['mempool_seconds']) for r in tx if r['mempool_seconds'] != 'NA']),
            prop.get(HOP1, NAN), prop.get(HOP2, NAN)]


def build_table(folder: str) -> List[list]:
    """One row per line of chain.csv, in the order of HEADER."""
    chain = list(csv.DictReader(open(os.path.join(folder, 'chain.csv'))))
    table = []
    first_time = previous = None
    for chain_row in chain:
        when = datetime.fromisoformat(chain_row['time_utc'].replace('Z', '+00:00'))
        first_time = first_time or when
        row = checkpoint_row(folder, chain_row, first_time, previous)
        table.append(row)
        chain_kb = int(chain_row['immutable_kb']) if chain_row.get('immutable_kb') else None
        previous = (when, int(chain_row['block']), chain_kb)
    return table


def write_csv(folder: str, table: List[list]) -> None:
    """Write the table to <folder>/growth.csv with two decimals for every number."""
    with open(os.path.join(folder, 'growth.csv'), 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(HEADER)
        writer.writerows([[f'{v:.2f}' if isinstance(v, float) else v for v in row] for row in table])


def print_table(table: List[list]) -> None:
    """Print the table on the screen."""
    print(f"{'cp':<6}{'hours':>6}{'block':>7}{'chainMB':>8}{'KB/blk':>7}{'blk/min':>8} |{'join s':>7}{'ready':>6}"
          f"{'sync':>6}{'MB/s':>6} |{'+100ms':>7}{'3 joins':>8} |{'tx blk':>7}{'mempool':>8} |{'hop1 ms':>8}{'hop2 ms':>8}")
    for r in table:
        print(f"{r[0]:<6}{r[1]:>6.1f}{r[2]:>7}{r[3]:>8.1f}{r[4]:>7.1f}{r[5]:>8.1f} |{r[6]:>7.1f}{r[7]:>6.1f}{r[8]:>6.1f}"
              f"{r[9]:>6.1f} |{r[10]:>7.1f}{r[11]:>8.1f} |{r[12]:>7.1f}{r[13]:>8.2f} |{r[14]:>8.0f}{r[15]:>8.0f}")


def main() -> None:
    """growth.py <results folder>: print the table and write growth.csv."""
    folder = sys.argv[1]
    table = build_table(folder)
    write_csv(folder, table)
    print_table(table)


if __name__ == '__main__':
    main()
