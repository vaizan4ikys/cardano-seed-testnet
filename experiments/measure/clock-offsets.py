#!/usr/bin/env python3
"""How far each machine's clock is ahead of this machine's clock.

    clock-offsets.py seedvm seedvm2 ...      prints  <machine>,<offset ms>,<round trip ms>

Asks each machine for its time over one kept-open ssh connection, 20 times, and trusts the
answer with the shortest round trip (the remote time is taken to be the midpoint). The error
is at most half of that round trip, a few ms. propagation.py uses the offsets to put the logs
of all machines on one timeline.
"""
import subprocess
import sys
import time

SAMPLES = 20
SSH = ['ssh', '-o', 'BatchMode=yes', '-o', 'ControlMaster=auto', '-o', 'ControlPersist=20',
       '-o', 'ControlPath=~/.ssh/clk-%C']


def measure(machine):
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


for machine in sys.argv[1:]:
    result = measure(machine)
    if result is None:
        sys.exit('no answer from ' + machine)
    print('{},{:.1f},{:.0f}'.format(machine, result[1] * 1000, result[0] * 1000))
