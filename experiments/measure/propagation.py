#!/usr/bin/env python3
"""Block propagation delay between nodes, from their logs.

Every node logs, with a millisecond timestamp, the moment a block becomes its chain tip:

    [2026-10-29 14:04:51.0295Z][...:ChainDB.AddBlockEvent.AddedToCurrentChain](Notice,16)
    Chain extended, new tip: <hash> at slot 1418

The first node that logs a hash is the one that forged the block. For every other node the
delay is its timestamp minus that first one. This compares clocks of different machines, so
it is only as accurate as their NTP sync (a few ms here).

    propagation.py --after 2026-10-29T14:00:00 pool1=pool1.log@60.4 seedvm2=seedvm2.log@3.3 ...

The optional @<ms> after a file name says how far that machine's clock is ahead of the reference
clock (see clock-offsets.py); it is subtracted from the timestamps of that log.

--after ignores blocks forged before that UTC time (use the end of the sync, otherwise a joiner
that is catching up shows the delay of old blocks). Prints one CSV row per node (stdout):

    node,blocks,median_ms,p95_ms,max_ms

and the block rate of the chain on stderr.
"""
import argparse
import re
import statistics
from datetime import datetime, timezone

LINE = re.compile(r'^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\.(\d+)Z\].*AddedToCurrentChain.*new tip: ([0-9a-f]{64})')


def read_log(path, offset_ms):
    """{block hash: UTC time in seconds when this node made it its tip}"""
    seen = {}
    for line in open(path, errors='replace'):
        m = LINE.match(line)
        if m:
            second = datetime.strptime(m[1], '%Y-%m-%d %H:%M:%S').replace(tzinfo=timezone.utc).timestamp()
            seen.setdefault(m[3], second + float('0.' + m[2]) - offset_ms / 1000)
    return seen


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--after', required=True, help='UTC time like 2026-10-29T14:00:00')
    parser.add_argument('--before', help='ignore blocks forged after this UTC time (a window in a log that goes on)')
    parser.add_argument('logs', nargs='+', metavar='name=file[@offset_ms]')
    args = parser.parse_args()
    after = datetime.fromisoformat(args.after).replace(tzinfo=timezone.utc).timestamp()

    nodes = {}
    for item in args.logs:
        name, rest = item.split('=', 1)
        path, _, offset = rest.partition('@')
        nodes[name] = read_log(path, float(offset or 0))

    # forger of each block: the node that logged it first
    forged = {}
    for name, seen in nodes.items():
        for block, t in seen.items():
            if block not in forged or t < forged[block][0]:
                forged[block] = (t, name)
    before = datetime.fromisoformat(args.before).replace(tzinfo=timezone.utc).timestamp() if args.before else float('inf')
    blocks = {b: f for b, f in forged.items() if after <= f[0] < before}

    for name, seen in nodes.items():
        delays = sorted((seen[b] - t) * 1000 for b, (t, forger) in blocks.items() if b in seen and forger != name)
        if delays:
            print('{},{},{:.0f},{:.0f},{:.0f}'.format(
                name, len(delays), statistics.median(delays), delays[int(0.95 * (len(delays) - 1))], delays[-1]))

    times = sorted(t for t, _ in blocks.values())
    if len(times) > 1:
        import sys
        print('# {} blocks in {:.0f} s = {:.1f} blocks/min'.format(
            len(times), times[-1] - times[0], 60 * (len(times) - 1) / (times[-1] - times[0])), file=sys.stderr)


if __name__ == '__main__':
    main()
