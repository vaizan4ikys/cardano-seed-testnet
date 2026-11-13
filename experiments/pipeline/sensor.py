#!/usr/bin/env python3
"""Simulated sensors. One JSON line per reading, sent over TCP to the gateway.

  python3 sensor.py --sensors 5 --interval 1 --duration 20 --port 9100
  python3 sensor.py --sensors 3 --interval 1 --duration 5 --stdout        (dry run)

Line format: {"sensor_id":"AGRI_001","seq":7,"ts":1760000000,"kind":"temperature","value":2450,"scale":100}
Values are integers: 2450 with scale 100 means 24.50.
"""
import argparse
import heapq
import json
import random
import socket
import sys
import time

KIND_LIST = ["temperature", "humidity", "soil_moisture"]
# kind: (normal low, normal high, scale)
RANGES = {"temperature": (10.0, 35.0, 100), "humidity": (30.0, 90.0, 10),
          "soil_moisture": (10.0, 60.0, 10)}


class SimSensor:
    def __init__(self, sensor_id, kind, rng, outlier_pct=0.0, seq_start=1):
        self.sensor_id, self.kind, self.rng = sensor_id, kind, rng
        self.outlier_pct = outlier_pct
        self.seq = seq_start
        lo, hi, _ = RANGES[kind]
        self.x = rng.uniform(lo + 0.2 * (hi - lo), hi - 0.2 * (hi - lo))

    def reading(self, ts):
        lo, hi, scale = RANGES[self.kind]
        span = hi - lo
        # bounded random walk: small steps, kept inside [lo, hi]
        self.x = min(hi, max(lo, self.x + self.rng.gauss(0, span * 0.02)))
        v = self.x
        if self.rng.random() * 100 < self.outlier_pct:   # out-of-range value
            off = self.rng.uniform(0.2, 0.6) * span
            v = hi + off if self.rng.random() < 0.5 else lo - off
        r = {"sensor_id": self.sensor_id, "seq": self.seq, "ts": int(ts),
             "kind": self.kind, "value": int(round(v * scale)), "scale": scale}
        self.seq += 1
        return r


class Sink:
    """Sends lines to the gateway over TCP (reconnects), or to stdout."""

    def __init__(self, host, port, to_stdout):
        self.host, self.port, self.to_stdout = host, port, to_stdout
        self.sock = None
        self.sent = self.dropped = 0

    def _connect(self):
        for _ in range(5):
            try:
                self.sock = socket.create_connection((self.host, self.port), timeout=5)
                return True
            except OSError:
                time.sleep(1)
        return False

    def send(self, line):
        if self.to_stdout:
            print(line, flush=True)
            self.sent += 1
            return
        data = (line + "\n").encode()
        for _ in range(2):
            if self.sock is None and not self._connect():
                break
            try:
                self.sock.sendall(data)
                self.sent += 1
                return
            except OSError:
                self.sock = None
        self.dropped += 1

    def close(self):
        if self.sock:
            self.sock.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sensors", type=int, default=5)
    ap.add_argument("--interval", type=float, default=5.0, help="seconds between readings of one sensor")
    ap.add_argument("--jitter", type=float, default=0.2, help="interval varies by +- this fraction")
    ap.add_argument("--duration", type=float, default=0, help="seconds to run; 0 = until Ctrl-C")
    ap.add_argument("--outlier-pct", type=float, default=2.0, help="per cent of out-of-range values")
    ap.add_argument("--silent-sensor", default=None, help="id of a sensor that goes silent, e.g. AGRI_002")
    ap.add_argument("--silent-after", type=float, default=10.0, help="seconds after start")
    ap.add_argument("--seq-start", type=int, default=1, help="first sequence number of every sensor")
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=9100)
    ap.add_argument("--stdout", action="store_true", help="print the lines instead of sending them")
    a = ap.parse_args()

    rng = random.Random(a.seed)
    sensors = [SimSensor("AGRI_%03d" % (i + 1), KIND_LIST[i % len(KIND_LIST)], rng,
                         a.outlier_pct, a.seq_start) for i in range(a.sensors)]
    sink = Sink(a.host, a.port, a.stdout)
    start = time.time()
    # first reading of each sensor at a random time inside the first interval
    heap = [(start + rng.uniform(0, a.interval), i) for i in range(len(sensors))]
    heapq.heapify(heap)
    try:
        while heap:
            due, i = heapq.heappop(heap)
            now = time.time()
            if a.duration and due - start >= a.duration:
                break
            if due > now:
                time.sleep(due - now)
            s = sensors[i]
            if s.sensor_id == a.silent_sensor and due - start >= a.silent_after:
                continue                        # silent: send nothing, never schedule again
            sink.send(json.dumps(s.reading(due), separators=(",", ":")))
            nxt = due + a.interval * (1 + rng.uniform(-a.jitter, a.jitter))
            heapq.heappush(heap, (nxt, i))
    except KeyboardInterrupt:
        pass
    sink.close()
    print("sensor: sent %d readings, dropped %d" % (sink.sent, sink.dropped), file=sys.stderr)


if __name__ == "__main__":
    main()
