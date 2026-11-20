#!/usr/bin/env python3
"""Simulated sensors. One JSON line per reading, sent over TCP to the gateway (gateway.py).

  python3 sensor.py --sensors 5 --interval 1 --duration 20 --port 9100
  python3 sensor.py --sensors 3 --interval 1 --duration 5 --stdout        (dry run: print, send nothing)
  python3 sensor.py --help                                                all options with their defaults

Sensors are named AGRI_001, AGRI_002, ... and take the kinds temperature, humidity, soil_moisture in turn.
Each value is a bounded random walk, with a few per cent out-of-range outliers (--outlier-pct).

No reading is given up: the gateway answers every line once the reading is safe on its disk, and a reading stays
here until its answer has come. While the gateway cannot be reached (stopped, restarting, network cut) the readings
wait and are sent when it is back (at most QUEUE_MAX; only then is a new reading dropped). At the end (--duration,
Ctrl-C or SIGTERM) the sensor waits up to FINISH_WAIT seconds for the last answers and prints on stderr
"sensor: sent N readings (confirmed by the gateway), M not confirmed, D dropped (queue full), X refused as bad".

Line format: {"sensor_id":"AGRI_001","seq":7,"ts":1760000000,"kind":"temperature","value":2450,"scale":100}
Values are integers: 2450 with scale 100 means 24.50.
"""
import argparse
import collections
import heapq
import itertools
import json
import random
import signal
import socket
import sys
import threading
import time
from typing import Any, Dict

KIND_LIST = ["temperature", "humidity", "soil_moisture"]      # sensor i gets kind i % 3
# kind: (normal low, normal high, scale)
RANGES = {"temperature": (10.0, 35.0, 100), "humidity": (30.0, 90.0, 10),
          "soil_moisture": (10.0, 60.0, 10)}
STEP_FRACTION = 0.02    # standard deviation of one random-walk step, as a fraction of the normal range
QUEUE_MAX = 100000      # readings kept while the gateway cannot be reached (10 sensors at 1 s: almost 3 hours)
CONNECT_TIMEOUT = 2     # seconds for one connection attempt
RECONNECT_AFTER = 1.0   # seconds between two connection attempts while the gateway cannot be reached
SOCKET_TIMEOUT = 5      # seconds a send may block before the connection counts as broken
FINISH_WAIT = 10        # seconds the sensor waits at the end for the answers to its last readings


class SimSensor:
    """One simulated sensor: a bounded random walk inside the normal range of its kind."""

    def __init__(self, sensor_id: str, kind: str, rng: random.Random, outlier_pct: float = 0.0,
                 seq_start: int = 1):
        self.sensor_id, self.kind, self.rng = sensor_id, kind, rng
        self.outlier_pct = outlier_pct
        self.seq = seq_start
        lo, hi, _ = RANGES[kind]
        self.x = rng.uniform(lo + 0.2 * (hi - lo), hi - 0.2 * (hi - lo))

    def reading(self, ts: float) -> Dict[str, Any]:
        """The next reading (as a dict, field order = line format) taken at time ts."""
        lo, hi, scale = RANGES[self.kind]
        span = hi - lo
        # bounded random walk: small steps, kept inside [lo, hi]
        self.x = min(hi, max(lo, self.x + self.rng.gauss(0, span * STEP_FRACTION)))
        v = self.x
        if self.rng.random() * 100 < self.outlier_pct:   # out-of-range value
            off = self.rng.uniform(0.2, 0.6) * span
            v = hi + off if self.rng.random() < 0.5 else lo - off
        r = {"sensor_id": self.sensor_id, "seq": self.seq, "ts": int(ts),
             "kind": self.kind, "value": int(round(v * scale)), "scale": scale}
        self.seq += 1
        return r


class Sink:
    """Sends lines to the gateway over TCP, or prints them (--stdout).

    The gateway answers every line with one line ("ok", "dup" or "bad"), in order, once the reading is safe on its
    disk. A line stays in `waiting` until its answer has come. After a broken connection every waiting line is sent
    again on the next one; the gateway answers "dup" for a reading it already has. Only one thread (the main loop)
    sends; a reader thread per connection takes the answers."""

    def __init__(self, host: str, port: int, to_stdout: bool):
        self.host, self.port, self.to_stdout = host, port, to_stdout
        self.lock = threading.Lock()
        self.waiting = collections.deque()  # lines without an answer, oldest first
        self.written = 0                    # how many of the first lines of `waiting` were sent on this connection
        self.sock = None
        self.conn = 0                       # number of the current connection (answers on an old one are ignored)
        self.next_connect = 0.0             # time.monotonic() before which no new connection is tried
        self.sent = self.dropped = self.bad = 0     # sent = stored by the gateway (answer "ok" or "dup")

    def send(self, line: str) -> None:
        """Keep one reading until the gateway has it, and send what is waiting (dry run: print it)."""
        if self.to_stdout:
            print(line, flush=True)
            self.sent += 1
            return
        with self.lock:
            if len(self.waiting) >= QUEUE_MAX:
                self.dropped += 1
                return
            self.waiting.append(line)
        self.pump()

    def pump(self) -> None:
        """Connect if needed (at most once per RECONNECT_AFTER seconds), then send the lines that were not sent on
        this connection yet. Never waits long: while the gateway cannot be reached the lines just wait."""
        with self.lock:
            if self.sock is None and not self._connect():
                return
            sock, conn = self.sock, self.conn
            todo = list(itertools.islice(self.waiting, self.written, None))
            self.written += len(todo)
        if todo:
            try:
                sock.sendall("".join(line + "\n" for line in todo).encode())
            except OSError:
                self._broken(conn)

    def _connect(self) -> bool:
        """Called with the lock held: open a connection and start its answer reader. False if that is not possible
        now. All waiting lines are sent again on the new connection."""
        if time.monotonic() < self.next_connect:
            return False
        try:
            sock = socket.create_connection((self.host, self.port), timeout=CONNECT_TIMEOUT)
        except OSError:
            self.next_connect = time.monotonic() + RECONNECT_AFTER
            return False
        sock.settimeout(SOCKET_TIMEOUT)
        self.conn += 1
        self.sock, self.written = sock, 0
        threading.Thread(target=self._read_answers, args=(sock, self.conn), daemon=True).start()
        return True

    def _read_answers(self, sock: socket.socket, conn: int) -> None:
        """Reader thread of one connection: every answer line removes the oldest waiting line."""
        rest = b""
        while True:
            try:
                chunk = sock.recv(4096)
            except socket.timeout:          # no answer for a while: fine, unless this connection was replaced
                with self.lock:
                    if conn != self.conn or self.sock is None:
                        return
                continue
            except OSError:
                break
            if not chunk:
                break
            rest += chunk
            *answers, rest = rest.split(b"\n")
            with self.lock:
                if conn != self.conn:
                    return
                for answer in answers:
                    if self.written == 0:   # an answer without a line: cannot happen
                        break
                    self.waiting.popleft()
                    self.written -= 1
                    if answer.strip() == b"bad":
                        self.bad += 1
                    else:
                        self.sent += 1
        self._broken(conn)

    def _broken(self, conn: int) -> None:
        """Connection number `conn` does not work any more: close it. The next pump() connects again."""
        with self.lock:
            if conn != self.conn or self.sock is None:
                return
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock, self.written = None, 0

    def finish(self, wait: float = FINISH_WAIT) -> int:
        """At the end: wait at most `wait` seconds until every reading has its answer. After 1 s without all
        answers the waiting readings are sent again on a new connection (Ctrl-C may have cut a send in the middle
        of a line). Returns the number of readings without an answer."""
        if not self.to_stdout:
            now = time.monotonic()
            end, fresh_at = now + wait, now + 1.0
            while self.waiting and time.monotonic() < end:
                if time.monotonic() >= fresh_at:
                    self._broken(self.conn)
                    fresh_at = end
                self.pump()
                time.sleep(0.05)
        with self.lock:
            if self.sock is not None:
                self.sock.close()
            self.sock = None
            self.conn += 1                  # the reader thread stops
            return len(self.waiting)


def main() -> None:
    """Read the options, then send readings in time order until --duration is over or Ctrl-C."""
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sensors", type=int, default=5, help="number of simulated sensors")
    ap.add_argument("--interval", type=float, default=5.0, help="seconds between readings of one sensor")
    ap.add_argument("--jitter", type=float, default=0.2, help="interval varies by +- this fraction")
    ap.add_argument("--duration", type=float, default=0, help="seconds to run; 0 = until Ctrl-C")
    ap.add_argument("--outlier-pct", type=float, default=2.0, help="per cent of out-of-range values")
    ap.add_argument("--silent-sensor", default=None, help="id of a sensor that goes silent, e.g. AGRI_002")
    ap.add_argument("--silent-after", type=float, default=10.0, help="seconds after start")
    ap.add_argument("--seq-start", type=int, default=1, help="first sequence number of every sensor")
    ap.add_argument("--first-id", type=int, default=1,
                    help="number of the first sensor id (AGRI_%%03d); gateways at different sites use different "
                         "ranges")
    ap.add_argument("--seed", type=int, default=None, help="random seed (default: different every run)")
    ap.add_argument("--host", default="127.0.0.1", help="gateway address")
    ap.add_argument("--port", type=int, default=9100, help="gateway TCP port")
    ap.add_argument("--stdout", action="store_true", help="print the lines instead of sending them")
    a = ap.parse_args()

    rng = random.Random(a.seed)
    sensors = [SimSensor("AGRI_%03d" % (a.first_id + i), KIND_LIST[i % len(KIND_LIST)], rng,
                         a.outlier_pct, a.seq_start) for i in range(a.sensors)]
    sink = Sink(a.host, a.port, a.stdout)

    def on_sigterm(*_):                     # SIGTERM ends the run like Ctrl-C (the last readings are delivered)
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, on_sigterm)
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
    unconfirmed = sink.finish()
    print("sensor: sent %d readings (confirmed by the gateway), %d not confirmed, %d dropped (queue full), "
          "%d refused as bad" % (sink.sent, unconfirmed, sink.dropped, sink.bad), file=sys.stderr)


if __name__ == "__main__":
    main()
