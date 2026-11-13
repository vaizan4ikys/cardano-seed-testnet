#!/usr/bin/env python3
"""Gateway: receives JSON-line readings over TCP, makes batches, hands them to a submit step.

  python3 gateway.py --B 100 --T 30 --listen-port 9100 --outbox outbox --submit dry
  python3 gateway.py --submit command --submit-command "./submit.sh {file} {hash}"

A batch is written when B readings are collected or the oldest reading has waited T seconds.
Outbox files:   batch-000017-<sha256>.json          the metadata (never changed)
                batch-000017-<sha256>.json.status   "pending" or "sent"
                state.json                          sequence numbers seen, next batch number
                dead/                               batches that failed --max-tries submits (not tried again)
After a restart every batch that is not "sent" is submitted again (same file, same hash).
Exit codes of the submit command: 0 = sent, 2 = REFUSED for good (for example the contract does not accept this
gateway): the batch goes to dead/ at once, without retries; any other code = failed, try again later.
"sent" only means that the submit step returned success (the node took the transaction into its
mempool), not that it is in a block. A crash between the submit and the status write sends the batch
again (at-least-once), so the submit command should be idempotent by batch hash.
The readings that wait in memory for their batch are lost if the process is killed
(Ctrl-C and SIGTERM write them out first).
"""
import argparse
import datetime
import glob
import json
import os
import shlex
import signal
import socketserver
import subprocess
import threading
import time

import layout

WINDOW = 2000       # sequence numbers remembered per sensor, for duplicate detection


def default_log(msg):
    stamp = datetime.datetime.now().strftime("%H:%M:%S")
    print("%s %s" % (stamp, msg), flush=True)


def write_atomic(path, data):
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def make_submit(mode, template=None, log=default_log, timeout=120):
    """Returns submit(path, hash) -> True (sent), False (failed, try again) or "refused" (never try again)."""
    if mode == "dry":
        def submit(path, h):
            log("DRY submit (nothing sent): %s" % os.path.basename(path))
            return True
        return submit
    if mode == "command":
        if not template:
            raise ValueError("command mode needs a command template")
        parts = shlex.split(template)
        has_ph = "{file}" in template or "{hash}" in template

        def submit(path, h):
            argv = [p.replace("{file}", path).replace("{hash}", h) for p in parts]
            if not has_ph:
                argv += [path, h]
            try:
                r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
            except (OSError, subprocess.TimeoutExpired) as e:
                log("submit command failed to run: %s" % e)
                return False
            tail = (r.stdout + r.stderr).strip()[-300:]
            if r.returncode == 2:
                log("REFUSED, not retried: %s" % (tail.splitlines()[-1] if tail else "exit code 2"))
                return "refused"
            if r.returncode != 0:
                log("submit command exit %d: %s" % (r.returncode, tail))
            return r.returncode == 0
        return submit
    raise ValueError("unknown submit mode: %s" % mode)


class Gateway:
    def __init__(self, outbox, B, T, submit, gateway_id="GW01", clock=time.monotonic, log=default_log,
                 tx_reserve=layout.TX_RESERVE, max_tries=5):
        if not layout.valid_id(gateway_id):
            raise ValueError("bad gateway id (use A-Z a-z 0-9 _ . -, 1-32 characters, not starting with 0x)")
        self.outbox, self.B, self.T, self.submit = outbox, B, T, submit
        self.gateway_id, self.clock, self.log = gateway_id, clock, log
        self.tx_reserve, self.max_tries = tx_reserve, max_tries
        os.makedirs(outbox, exist_ok=True)
        self.state_path = os.path.join(outbox, "state.json")
        self.lock = threading.RLock()
        self.send_lock = threading.Lock()
        self.buf = []                     # (arrival time, reading)
        self.seen = {}                    # sensor_id -> set of sequence numbers
        self.next_batch = 1
        self.maxseq = {}                  # sensor_id -> highest sequence number seen
        self.warned = set()               # sensors already reported once (bad data / restart)
        self.retry_flush_at = 0.0
        self.closed = False
        self.stats = {"received": 0, "dup": 0, "bad": 0, "late": 0, "batches": 0, "dead": 0}
        self.stop_ev = threading.Event()
        self.wake = threading.Event()
        self.threads = []
        self._load_state()

    # state ------------------------------------------------------------
    def _load_state(self):
        try:
            with open(self.state_path) as f:
                st = json.load(f)
            self.seen = {k: set(v) for k, v in st["seen"].items()}
            self.next_batch = st["next_batch"]
        except (OSError, ValueError, KeyError):
            pass
        self.maxseq = {k: max(v) for k, v in self.seen.items() if v}
        for p in (glob.glob(os.path.join(self.outbox, "batch-*.json")) +
                  glob.glob(os.path.join(self.outbox, "dead", "batch-*.json"))):   # state file lost: use the files
            n = int(os.path.basename(p).split("-")[1])
            self.next_batch = max(self.next_batch, n + 1)

    def _save_state(self):
        st = {"next_batch": self.next_batch,
              "seen": {k: sorted(v)[-WINDOW:] for k, v in self.seen.items()}}
        try:
            write_atomic(self.state_path, json.dumps(st).encode())
        except OSError as e:
            self.log("ERROR cannot write state file: %s" % e)

    # receiving --------------------------------------------------------
    def count_bad(self):
        with self.lock:
            self.stats["bad"] += 1

    def _reject(self, raw, err):
        """Called with the lock held. Count the reading; log once per sensor."""
        self.stats["bad"] += 1
        sid = raw.get("sensor_id") if isinstance(raw, dict) else None
        key = repr(sid)[:40] if sid is not None else "?"
        if key not in self.warned and len(self.warned) < 1000:
            self.warned.add(key)
            self.log("rejected reading of sensor %s: %s (more from this sensor are counted, not logged)"
                     % (key, err))

    def add_reading(self, raw, now=None):
        """Returns "ok", "dup", "bad" or "closed"."""
        with self.lock:
            if self.closed:
                self.stats["late"] += 1
                return "closed"
            try:
                r = layout.parse_reading(raw)
            except ValueError as e:
                self._reject(raw, e)
                return "bad"
            now = self.clock() if now is None else now
            sid = r["sensor_id"]
            top = self.maxseq.get(sid, -1)
            if top - r["seq"] > 1000 and "restart:" + sid not in self.warned and len(self.warned) < 1000:
                self.warned.add("restart:" + sid)
                self.log("WARNING sensor %s: seq %d is far below the highest seen (%d): sensor restarted? "
                         "readings dropped as duplicates" % (sid, r["seq"], top))
            s = self.seen.setdefault(sid, set())
            if r["seq"] in s:
                self.stats["dup"] += 1
                return "dup"
            s.add(r["seq"])
            self.maxseq[sid] = max(top, r["seq"])
            if len(s) > 2 * WINDOW:
                self.seen[sid] = set(sorted(s)[-WINDOW:])
            self.stats["received"] += 1
            self.buf.append((now, r))
            if len(self.buf) >= self.B:
                self._flush("B", now)
            return "ok"

    def tick(self, now=None):
        """Flush when the oldest waiting reading is T seconds old."""
        with self.lock:
            now = self.clock() if now is None else now
            if self.buf and now - self.buf[0][0] >= self.T and now >= self.retry_flush_at:
                self._flush("T", now)

    def flush_now(self):
        with self.lock:
            if self.buf:
                self._flush("shutdown", self.clock())

    def _flush(self, reason, now):
        """Write the buffer as one or more batch files. Called with the lock held."""
        items, self.buf = self.buf, []
        arrival = {id(r): t for t, r in items}
        chunks = layout.fit_chunks([r for _, r in items], self.gateway_id, self.tx_reserve)
        for i, chunk in enumerate(chunks):
            obj = layout.build_batch(self.gateway_id, self.next_batch, chunk)
            data = layout.dump(obj)
            h = layout.batch_hash(data)
            path = os.path.join(self.outbox, "batch-%06d-%s.json" % (self.next_batch, h))
            try:
                write_atomic(path, data)
                write_atomic(path + ".status", b"pending")
            except OSError as e:           # disk problem: keep the readings in memory, try again later
                rest = [x for c in chunks[i:] for x in c]
                self.buf = [(arrival[id(r)], r) for r in rest] + self.buf
                self.retry_flush_at = now + 1.0
                self.log("ERROR cannot write batch file (%s); %d readings kept in memory" % (e, len(rest)))
                break
            wait = now - min(arrival[id(r)] for r in chunk)
            self.log("batch %d: %d readings, %d bytes json, ~%d bytes tx, wait of oldest %.2fs, "
                     "reason %s, hash %s" % (self.next_batch, len(chunk), len(data),
                                             layout.tx_estimate(obj, self.tx_reserve), wait, reason, h))
            self.next_batch += 1
            self.stats["batches"] += 1
        self._save_state()
        self.wake.set()

    # sending ----------------------------------------------------------
    def _status(self, path):
        """Returns "sent" or the number of failed tries so far (0 when none or no status file)."""
        try:
            with open(path + ".status") as f:
                words = f.read().split()
        except OSError:
            return 0
        if words and words[0] == "sent":
            return "sent"
        return int(words[1]) if len(words) > 1 and words[1].isdigit() else 0

    def pending_files(self):
        return [p for p in sorted(glob.glob(os.path.join(self.outbox, "batch-*.json")))
                if self._status(p) != "sent"]

    def _dead_letter(self, p, tries, why=None):
        dead = os.path.join(self.outbox, "dead")
        os.makedirs(dead, exist_ok=True)
        write_atomic(p + ".status", b"dead %d" % tries)
        os.replace(p, os.path.join(dead, os.path.basename(p)))
        os.replace(p + ".status", os.path.join(dead, os.path.basename(p) + ".status"))
        self.stats["dead"] += 1
        self.log("DEAD LETTER: %s %s, moved to %s (not tried again; the readings are NOT on the chain)"
                 % (os.path.basename(p), why or "failed %d submits" % tries, dead))

    def send_pending(self):
        """Submit pending batches, oldest first. A failure stops the run (retry later, keeps the
        order), except when the batch has now failed max_tries times: it goes to dead/ and the
        next batches are tried."""
        with self.send_lock:
            for p in self.pending_files():
                with open(p, "rb") as f:
                    h = layout.batch_hash(f.read())
                if h not in os.path.basename(p):
                    self.log("ERROR %s does not match its hash, skipped" % os.path.basename(p))
                    continue
                try:
                    ok = self.submit(p, h)
                except Exception as e:
                    self.log("submit error: %s" % e)
                    ok = False
                if ok == "refused":
                    self._dead_letter(p, self._status(p) + 1, "was refused")
                    continue
                if not ok:
                    tries = self._status(p) + 1
                    self.log("not sent: %s (try %d of %d)" % (os.path.basename(p), tries, self.max_tries))
                    if tries >= self.max_tries:
                        self._dead_letter(p, tries)
                        continue
                    write_atomic(p + ".status", b"pending %d" % tries)
                    return False
                write_atomic(p + ".status", b"sent")
                self.log("sent: %s" % os.path.basename(p))
            return True

    # threads ----------------------------------------------------------
    def start(self, retry=10.0):
        def flusher():
            while not self.stop_ev.wait(0.1):
                self.tick()

        def sender():
            while not self.stop_ev.is_set():
                self.wake.wait(retry)
                self.wake.clear()
                if not self.stop_ev.is_set():
                    self.send_pending()
        self.wake.set()                   # resend what a former run left pending
        self.threads = [threading.Thread(target=flusher, daemon=True),
                        threading.Thread(target=sender, daemon=True)]
        for t in self.threads:
            t.start()

    def shutdown(self):
        self.stop_ev.set()
        self.wake.set()
        for t in self.threads:
            t.join(timeout=5)
        with self.lock:
            self.flush_now()
            self.closed = True            # readings arriving later are refused and counted as "late"
        self.send_pending()
        self.log("stopped: %s" % self.stats)


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        gw = self.server.gw
        while True:
            line = self.rfile.readline(65536)
            if not line:
                break
            line = line.strip()
            if not line:
                continue
            try:
                raw = json.loads(line)
            except (ValueError, RecursionError):
                gw.count_bad()
                continue
            if gw.add_reading(raw) == "closed":
                break


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--B", type=int, default=100, help="readings per batch")
    ap.add_argument("--T", type=float, default=30.0, help="max seconds the oldest reading waits")
    ap.add_argument("--listen-host", default="127.0.0.1")
    ap.add_argument("--listen-port", type=int, default=9100)
    ap.add_argument("--outbox", default="outbox")
    ap.add_argument("--gateway-id", default="GW01")
    ap.add_argument("--submit", choices=["dry", "command"], default="dry")
    ap.add_argument("--submit-command", default=None,
                    help='template, e.g. "./submit.sh {file} {hash}" (no {..} = both appended)')
    ap.add_argument("--tx-reserve", type=int, default=layout.TX_RESERVE,
                    help="bytes of the transaction besides the metadata (plain ~300, contract ~1230)")
    ap.add_argument("--max-tries", type=int, default=5, help="failed submits before a batch goes to dead/")
    ap.add_argument("--retry", type=float, default=10.0, help="seconds between resends of pending batches")
    a = ap.parse_args()
    if a.B < 1 or a.T <= 0:
        ap.error("--B must be >= 1 and --T > 0")
    if a.max_tries < 1 or not 0 <= a.tx_reserve < layout.MAX_TX:
        ap.error("--max-tries must be >= 1 and --tx-reserve between 0 and %d" % layout.MAX_TX)
    if not layout.valid_id(a.gateway_id):
        ap.error("--gateway-id: use A-Z a-z 0-9 _ . -, 1-32 characters, not starting with 0x")

    gw = Gateway(a.outbox, a.B, a.T, make_submit(a.submit, a.submit_command), a.gateway_id,
                 tx_reserve=a.tx_reserve, max_tries=a.max_tries)
    srv = Server((a.listen_host, a.listen_port), Handler)
    srv.gw = gw
    gw.start(a.retry)
    stop = lambda *_: threading.Thread(target=srv.shutdown).start()
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    gw.log("listening on %s:%d, B=%d T=%gs, outbox=%s, submit=%s" %
           (a.listen_host, srv.server_address[1], a.B, a.T, a.outbox, a.submit))
    srv.serve_forever()
    srv.server_close()
    gw.shutdown()


if __name__ == "__main__":
    main()
