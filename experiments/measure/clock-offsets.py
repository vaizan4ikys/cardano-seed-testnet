#!/usr/bin/env python3
"""How far each machine's clock is ahead of this machine's clock.

Usage:
    clock-offsets.py seedvm seedvm2 ...      prints  <machine>,<offset ms>,<round trip ms>

Asks each machine for its time over one kept-open ssh connection, 20 times, and trusts the
answer with the shortest round trip (the remote time is taken to be the midpoint). The error
is at most half of that round trip, a few ms. propagation.py uses the offsets to put the logs
of all machines on one timeline.

Reads: nothing (only the ssh answers). Writes: one CSV line per machine on stdout, for example
    seedvm2,3.3,2
Exits with an error message if a machine does not answer at all.
"""
import subprocess
import sys
import time
from typing import Optional, Tuple

# How many times each machine is asked; the answer with the shortest round trip wins.
SAMPLES = 20

# ssh options: no password prompt, and one connection that stays open (ControlMaster) for 20 s,
# so that only the first of the SAMPLES questions pays for the ssh handshake.
SSH = ['ssh', '-o', 'BatchMode=yes', '-o', 'ControlMaster=auto', '-o', 'ControlPersist=20',
       '-o', 'ControlPath=~/.ssh/clk-%C']


def measure(machine: str) -> Optional[Tuple[float, float]]:
    """Return (round trip in s, offset in s) of the best of SAMPLES answers, or None if none came.

    The offset is the remote clock minus this machine's clock, with the remote time taken to be
    half way between sending the question and receiving the answer.
    """
    best = None
    for _ in range(SAMPLES):
        sent = time.time()
        answer = subprocess.run(SSH + [machine, 'date +%s.%N'], capture_output=True, text=True).stdout
        received = time.time()
        try:
            remote = float(answer.strip())
        except ValueError:
            continue
        round_trip = received - sent
        if best is None or round_trip < best[0]:
            best = (round_trip, remote - (sent + received) / 2)
    return best


def main() -> None:
    """Print one line per machine named on the command line."""
    for machine in sys.argv[1:]:
        result = measure(machine)
        if result is None:
            sys.exit('no answer from ' + machine)
        print('{},{:.1f},{:.0f}'.format(machine, result[1] * 1000, result[0] * 1000))


if __name__ == '__main__':
    main()
