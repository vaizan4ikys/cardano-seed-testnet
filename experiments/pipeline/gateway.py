#!/usr/bin/env python3
"""Gateway: receives JSON-line readings over TCP, makes batches, hands them to a submit step.

Runs on a gateway machine (a chain VM in the lab). Sensors (sensor.py) connect to --listen-port and send one JSON
reading per line; the gateway checks them (layout.py), drops duplicates, writes batch files and calls the submit step.

  python3 gateway.py --B 100 --T 30 --listen-port 9100 --outbox outbox --submit dry
  python3 gateway.py --submit command --submit-command "./submit.sh {file} {hash}" --kupo http://10.150.0.71:1442
  python3 gateway.py --help          all options with their defaults

A batch is written when B readings are collected or the oldest reading has waited T seconds.
Outbox files:   batch-000017-<sha256>.json          the metadata (never changed)
                batch-000017-<sha256>.json.status   "pending", "settling", "final" or "sent" (see below)
                batch-000017-<sha256>.json.tx       the transaction of a "settling" or "final" batch (JSON)
                state.json                          sequence numbers seen, next batch number
                dead/                               batches that failed --max-tries submits (not tried again)
After a restart every batch that is "pending" is submitted again (same file, same hash).
Exit codes of the submit command: 0 = sent, 2 = REFUSED for good (for example the contract does not accept this
gateway): the batch goes to dead/ at once, without retries; any other code = failed, try again later.
A crash between the submit and the status write sends the batch again (at-least-once), so the submit command
should be idempotent by batch hash.

Critical data: with --kupo a batch is kept until its transaction is FINAL. The submit command returns 0 when the
transaction is in a block once; but that block can be replaced by a competing block of another pool (on the lab
chain about 6 % of the forged blocks: 59 of 1,008 in 85 minutes), and Cardano does not put the transactions of a
replaced block back. The states:
  pending    written, not sent yet (or a submit failed and will be tried again, or the transaction vanished and the
             batch must be sent again: then its .tx file is still there)
  settling   submitted. The transaction id (the last 64-hex word of the last line the submit command prints on
             stdout) is in the .tx file. Every --confirm-interval seconds each settling batch is looked up in Kupo,
             the same way as the web page does it: in a block -> how many blocks on top; at --final-blocks (default
             60 = k) -> final. Missing for longer than --missing-grace seconds (Kupo is normally less than a second
             behind, so the transaction was in a replaced block) -> logged and set back to pending. The sender
             thread then submits it again like any new batch (oldest first, because every batch spends the coin
             of the one before): same file, same hash, a new transaction. The check never waits for a submit, so
             new batches are not held up. A resend that is refused for good goes to dead/ like a first submit; one
             that failed --max-tries times goes to dead/ too, unless its transaction is in the chain after all.
  final      the transaction is final: nothing more to do (the files stay as the record)
  sent       submitted, but not followed: dry mode, no --kupo, or no transaction id in the output of the submit
             command (the old gateway wrote only this). Such a batch is not checked.
A restart keeps the settling batches and goes on with them. The node tip comes from reader.DockerTip (docker exec).
check_batches.py reads an outbox and the chain and tells whether every batch arrived.
The readings that wait in memory for their batch are lost if the process is killed
(Ctrl-C and SIGTERM write them out first).
"""
from __future__ import annotations

import argparse
import datetime
import glob
import json
import os
import re
import shlex
import signal
import socketserver
import subprocess
import threading
import time
from typing import Any, Callable, Dict, List, Optional, Tuple, Union

import confirm
import layout
import reader

WINDOW = 2000           # sequence numbers remembered per sensor, for duplicate detection
SEQ_JUMP_WARN = 1000    # warn when a sequence number is this far below the highest seen (sensor restarted?)
MAX_WARNED = 1000       # at most this many "first problem of a sensor" log lines (keeps the log and memory small)
MAX_LINE = 65536        # longest line accepted from a sensor (bytes)
SUBMIT_TIMEOUT = 120    # seconds a submit command may run
EXIT_SENT, EXIT_REFUSED = 0, 2     # exit codes of the submit command (anything else = failed, retry later)
FINAL_BLOCKS = 60       # blocks on top of a transaction until it is final (k of this chain)
CONFIRM_INTERVAL = 15   # seconds between two looks at the batches that are not final yet
MISSING_GRACE = 60      # seconds a transaction may be missing in Kupo before the batch is sent again
TXID_RE = re.compile(r"\b[0-9a-f]{64}\b")
IN_PROGRESS = ("sent", "settling", "final")     # status words of a batch that was submitted (not "pending")

# What a submit step returns: True (sent, transaction id not known), a 64-hex transaction id (sent, and this is
# the transaction), False (failed, try again) or "refused" (never try again).
SubmitResult = Union[bool, str]
Submit = Callable[[str, str], SubmitResult]


def default_log(msg: str) -> None:
    """Print one line with the time of day."""
    stamp = datetime.datetime.now().strftime("%H:%M:%S")
    print("%s %s" % (stamp, msg), flush=True)


def write_atomic(path: str, data: bytes) -> None:
    """Write a file so that a crash leaves either the old or the new content (temp file, fsync, rename)."""
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def find_txid(output: str, batch_hash: str) -> Optional[str]:
    """The transaction id in the last line of the submit command's STDOUT: the last 64-hex word of that line that
    is not the batch hash (p1-batch.sh prints "... batch HASH is in a block: tx TXID (...)"). None if none.
    Pass stdout only: the notes of the script on stderr ("sent the same transaction again", "registry.ref ...")
    come last and must not be taken for the answer."""
    lines = output.strip().splitlines()
    words = [w for w in TXID_RE.findall(lines[-1]) if w != batch_hash] if lines else []
    return words[-1] if words else None


def make_submit(mode: str, template: Optional[str] = None, log: Callable[[str], None] = default_log,
                timeout: int = SUBMIT_TIMEOUT) -> Submit:
    """Returns submit(path, hash) -> True (sent), the transaction id (sent; the command printed it as the last
    64-hex word of its last stdout line), False (failed, try again) or "refused" (never try again).

    mode "dry" sends nothing; mode "command" runs the template (words {file} and {hash} are replaced; without
    them the file and the hash are appended as the last two arguments)."""
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
            if r.returncode == EXIT_REFUSED:
                log("REFUSED, not retried: %s" % (tail.splitlines()[-1] if tail else "exit code 2"))
                return "refused"
            if r.returncode != EXIT_SENT:
                log("submit command exit %d: %s" % (r.returncode, tail))
                return False
            return find_txid(r.stdout, h) or True
        return submit
    raise ValueError("unknown submit mode: %s" % mode)


class Gateway:
    """Collects readings, writes them as batch files into the outbox and submits the batch files.

    B = readings per batch, T = seconds the oldest reading may wait. Thread safety: self.lock protects the
    reading buffer and the counters, self.send_lock makes sure only one thread submits at a time.
    view = a confirm.ChainView (or None: submitted batches are then not followed to "final")."""

    def __init__(self, outbox: str, B: int, T: float, submit: Submit, gateway_id: str = "GW01",
                 clock: Callable[[], float] = time.monotonic, log: Callable[[str], None] = default_log,
                 tx_reserve: int = layout.TX_RESERVE, max_tries: int = 5,
                 view: Optional[confirm.ChainView] = None, final_blocks: int = FINAL_BLOCKS,
                 missing_grace: float = MISSING_GRACE):
        if not layout.valid_id(gateway_id):
            raise ValueError("bad gateway id (use A-Z a-z 0-9 _ . -, 1-32 characters, not starting with 0x)")
        self.outbox, self.B, self.T, self.submit = outbox, B, T, submit
        self.gateway_id, self.clock, self.log = gateway_id, clock, log
        self.tx_reserve, self.max_tries = tx_reserve, max_tries
        self.view, self.final_blocks, self.missing_grace = view, final_blocks, missing_grace
        self.missing_since = {}           # txid -> time (self.clock) when it was first missing in Kupo
        self.view_problem = None          # why the last look at the chain failed (logged once)
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
        self.stats = {"received": 0, "dup": 0, "bad": 0, "late": 0, "batches": 0, "dead": 0, "final": 0, "resent": 0}
        self.stop_ev = threading.Event()
        self.wake = threading.Event()
        self.threads = []
        self._load_state()

    # state ------------------------------------------------------------
    def _load_state(self):
        """Read state.json; if it is lost, at least continue the batch numbers after the files in the outbox."""
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
        """Write state.json (only the last WINDOW sequence numbers of every sensor)."""
        st = {"next_batch": self.next_batch,
              "seen": {k: sorted(v)[-WINDOW:] for k, v in self.seen.items()}}
        try:
            write_atomic(self.state_path, json.dumps(st).encode())
        except OSError as e:
            self.log("ERROR cannot write state file: %s" % e)

    # receiving --------------------------------------------------------
    def count_bad(self):
        """Count a line that is not JSON (called by the TCP handler)."""
        with self.lock:
            self.stats["bad"] += 1

    def _reject(self, raw, err):
        """Called with the lock held. Count the reading; log once per sensor."""
        self.stats["bad"] += 1
        sid = raw.get("sensor_id") if isinstance(raw, dict) else None
        key = repr(sid)[:40] if sid is not None else "?"
        if key not in self.warned and len(self.warned) < MAX_WARNED:
            self.warned.add(key)
            self.log("rejected reading of sensor %s: %s (more from this sensor are counted, not logged)"
                     % (key, err))

    def add_reading(self, raw: object, now: Optional[float] = None) -> str:
        """Check one received reading and put it into the buffer. Returns "ok", "dup", "bad" or "closed"."""
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
            if (top - r["seq"] > SEQ_JUMP_WARN and "restart:" + sid not in self.warned
                    and len(self.warned) < MAX_WARNED):
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

    def tick(self, now: Optional[float] = None) -> None:
        """Flush when the oldest waiting reading is T seconds old."""
        with self.lock:
            now = self.clock() if now is None else now
            if self.buf and now - self.buf[0][0] >= self.T and now >= self.retry_flush_at:
                self._flush("T", now)

    def flush_now(self):
        """Write whatever is in the buffer as batches (used at shutdown)."""
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
    def _status(self, path: str) -> Tuple[str, int]:
        """(word, failed tries so far) from the status file: word is "sent", "settling", "final" or "pending"
        (also when there is no status file). The file holds one of "pending", "pending <tries>", "sent",
        "settling", "final"."""
        try:
            with open(path + ".status") as f:
                words = f.read().split()
        except OSError:
            return "pending", 0
        if words and words[0] in IN_PROGRESS:
            return words[0], 0
        return "pending", int(words[1]) if len(words) > 1 and words[1].isdigit() else 0

    def pending_files(self) -> List[str]:
        """Batch files that are not submitted yet, oldest first."""
        return [p for p in sorted(glob.glob(os.path.join(self.outbox, "batch-*.json")))
                if self._status(p)[0] == "pending"]

    def settling_files(self) -> List[str]:
        """Batch files that are submitted but not final yet, oldest first."""
        return [p for p in sorted(glob.glob(os.path.join(self.outbox, "batch-*.json")))
                if self._status(p)[0] == "settling"]

    def _load_tx(self, p: str) -> Optional[Dict[str, Any]]:
        """The .tx file of a batch (see _new_tx), or None if it is missing or damaged."""
        try:
            with open(p + ".tx") as f:
                rec = json.load(f)
            return rec if isinstance(rec["txid"], str) else None
        except (OSError, ValueError, KeyError, TypeError):
            return None

    def _save_tx(self, p: str, rec: Dict[str, Any]) -> None:
        """Write the .tx file (atomically)."""
        write_atomic(p + ".tx", json.dumps(rec).encode())

    @staticmethod
    def _new_tx(txid: str, resends: int = 0) -> Dict[str, Any]:
        """What is remembered of a submitted transaction: the id, where Kupo showed it (slot, block header hash,
        block number = tip block when first seen) and how often the batch was sent again."""
        return {"txid": txid, "slot": None, "header": None, "block": None, "resends": resends}

    def _dead_letter(self, p: str, tries: int, why: Optional[str] = None) -> None:
        """Move a batch file, its status (and its .tx file) to dead/ (never tried again)."""
        dead = os.path.join(self.outbox, "dead")
        os.makedirs(dead, exist_ok=True)
        write_atomic(p + ".status", b"dead %d" % tries)
        os.replace(p, os.path.join(dead, os.path.basename(p)))
        os.replace(p + ".status", os.path.join(dead, os.path.basename(p) + ".status"))
        if os.path.exists(p + ".tx"):
            os.replace(p + ".tx", os.path.join(dead, os.path.basename(p) + ".tx"))
        self.stats["dead"] += 1
        self.log("DEAD LETTER: %s %s, moved to %s (not tried again; the readings are NOT on the chain)"
                 % (os.path.basename(p), why or "failed %d submits" % tries, dead))

    def _mark_sent(self, p: str, txid: Optional[str]) -> None:
        """A submit worked. With a transaction id and a chain view the batch is "settling" (followed until final),
        else "sent". The .tx file is written first: a crash in between only means one more (idempotent) submit.
        A pending batch that still has a .tx file was sent before: this is a resend (log line "sent again:")."""
        name = os.path.basename(p)
        old = self._load_tx(p)
        again = "sent again" if old else "sent"
        if txid and self.view:
            if old and txid == old["txid"]:             # the node still has the old transaction: nothing new
                write_atomic(p + ".status", b"settling")
                self.log("batch %s: the node still has its transaction (mempool); waiting" % name)
                return
            resends = old["resends"] + 1 if old else 0
            self._save_tx(p, self._new_tx(txid, resends))
            write_atomic(p + ".status", b"settling")
            if old:
                self.stats["resent"] += 1
                self.log("sent again: %s (new transaction %s..., resend %d)" % (name, txid[:12], resends))
            else:
                self.log("sent: %s (transaction %s...)" % (name, txid[:12]))
        else:
            write_atomic(p + ".status", b"sent")
            self.log("sent again: %s (no transaction id: not followed any more)" % name if old
                     else "sent: %s" % name)

    def _back_to_settling(self, p: str) -> Optional[bool]:
        """Before a batch that was once in the chain (it has a .tx file) goes to dead/: ask Kupo for its
        transaction. If it is there, the batch is "settling" again and is followed (True). False: it is not
        there, or the batch was never sent. None: Kupo cannot be asked now (decide later)."""
        rec = self._load_tx(p)
        if rec is None or not self.view:
            return False
        try:
            found = self.view.locate(rec["txid"], rec["slot"])
        except Exception as e:
            self.log("cannot ask Kupo about %s: %s" % (os.path.basename(p), e))
            return None
        if found is None:
            return False
        write_atomic(p + ".status", b"settling")
        self.missing_since.pop(rec["txid"], None)
        self.log("batch %s: not sent again, but its transaction %s... is in the chain: following it"
                 % (os.path.basename(p), rec["txid"][:12]))
        return True

    def send_pending(self) -> bool:
        """Submit pending batches, oldest first (a resend is a pending batch too). A failure stops the run (retry
        later, keeps the order), except when the batch has now failed max_tries times: it goes to dead/ and the
        next batches are tried. Returns True when nothing is left pending."""
        with self.send_lock:
            for p in self.pending_files():
                with open(p, "rb") as f:
                    h = layout.batch_hash(f.read())
                if h not in os.path.basename(p):
                    self.log("ERROR %s does not match its hash, skipped" % os.path.basename(p))
                    continue
                again = " when sent again" if self._load_tx(p) else ""
                try:
                    ok = self.submit(p, h)
                except Exception as e:
                    self.log("submit error: %s" % e)
                    ok = False
                if ok == "refused":
                    self._dead_letter(p, self._status(p)[1] + 1, "was refused" + again)
                    continue
                if not ok:
                    tries = self._status(p)[1] + 1
                    self.log("not sent%s: %s (try %d of %d)" % (again, os.path.basename(p), tries, self.max_tries))
                    if tries >= self.max_tries:
                        followed = self._back_to_settling(p)
                        if followed is None:                    # Kupo cannot say: decide at the next try
                            write_atomic(p + ".status", b"pending %d" % tries)
                            return False
                        if not followed:
                            self._dead_letter(p, tries, "failed %d submits%s" % (tries, again))
                        continue
                    write_atomic(p + ".status", b"pending %d" % tries)
                    return False
                self._mark_sent(p, ok if isinstance(ok, str) else None)
            return True

    # following the batches until they are final ----------------------------
    def check_settling(self) -> None:
        """One round: look at every settling batch (oldest first) in Kupo. In a block: count its depth, final at
        final_blocks. Missing for longer than missing_grace: mark it for a resend (the sender thread sends it).
        Does nothing without a chain view. When Kupo or the node cannot be asked, nothing is concluded (a Kupo
        problem is not a replaced block). This never submits anything, so it never holds up the sender."""
        files = self.settling_files() if self.view else []
        if not files:
            return
        why = self.view.refresh()
        if why:
            if why != self.view_problem:
                self.log("cannot check the settling batches now: %s (they are kept; trying again)" % why)
            self.view_problem = why
            return
        if self.view_problem:
            self.log("the chain can be checked again")
            self.view_problem = None
        for p in files:
            if not self._check_one(p):
                break                                   # Kupo failed: try the whole round again later

    def _check_one(self, p: str) -> bool:
        """Look at one settling batch. Returns False when the round must stop (Kupo could not be asked)."""
        name = os.path.basename(p)
        rec = self._load_tx(p)
        if rec is None:                                 # cannot happen normally (.tx is written before the status)
            self.log("ERROR %s is settling but has no readable .tx file: not followed any more" % name)
            write_atomic(p + ".status", b"sent")
            return True
        try:
            found = self.view.locate(rec["txid"], rec["slot"])
        except Exception as e:
            self.log("cannot ask Kupo about %s: %s" % (name, e))
            return False
        if found is None:
            self._mark_if_missing(p, rec)
        else:
            self.missing_since.pop(rec["txid"], None)
            self._count_depth(p, rec, found)
        return True

    def _count_depth(self, p: str, rec: Dict[str, Any], found: Tuple[int, Optional[str]]) -> None:
        """The transaction is in a block (found = slot, header hash): remember it, count the blocks on top, and
        make the batch "final" at final_blocks. If the block changed, counting starts again."""
        name = os.path.basename(p)
        slot, header = found
        changed = (slot, header) != (rec["slot"], rec["header"])
        if rec["block"] is None or slot != rec["slot"]:
            if rec["slot"] is not None and slot != rec["slot"]:
                self.log("batch %s: its transaction is now in another block (slot %d, was %d): counting again"
                         % (name, slot, rec["slot"]))
            rec["block"] = self.view.new_block(slot)
            changed = True
        rec["slot"], rec["header"] = slot, header
        depth = self.view.depth(rec["block"])
        if depth is not None and depth >= self.final_blocks:
            self._save_tx(p, rec)
            write_atomic(p + ".status", b"final")
            self.stats["final"] += 1
            self.log("final: %s (transaction %s..., %d blocks deep)" % (name, rec["txid"][:12], depth))
        elif changed:
            self._save_tx(p, rec)

    def _mark_if_missing(self, p: str, rec: Dict[str, Any]) -> None:
        """The transaction is not in Kupo. Wait for missing_grace seconds (Kupo may be a moment behind); then set
        the batch back to "pending" and wake the sender, which submits the same file again (a new transaction).
        The .tx file stays: it tells the sender that this is a resend and how often the batch was sent before."""
        txid = rec["txid"]
        since = self.missing_since.setdefault(txid, self.clock())
        if self.clock() - since < self.missing_grace:
            return
        self.log("batch %s: its transaction is no longer in the chain (block replaced): sending it again"
                 % os.path.basename(p))
        del self.missing_since[txid]
        write_atomic(p + ".status", b"pending")
        self.wake.set()

    # threads ----------------------------------------------------------
    def start(self, retry: float = 10.0, check: float = CONFIRM_INTERVAL) -> None:
        """Start the background threads: flusher (T timeout), sender (submits, retries every `retry` s) and
        checker (looks at the settling batches every `check` s; only with a chain view)."""
        def flusher():
            while not self.stop_ev.wait(0.1):
                self.tick()

        def sender():
            while not self.stop_ev.is_set():
                self.wake.wait(retry)
                self.wake.clear()
                if not self.stop_ev.is_set():
                    self.send_pending()
        def checker():
            while not self.stop_ev.wait(check):
                try:
                    self.check_settling()
                except Exception as e:      # a bug or a bad answer must not stop the checking for good
                    self.log("ERROR while checking the settling batches: %s" % e)
        self.wake.set()                   # resend what a former run left pending
        self.threads = [threading.Thread(target=flusher, daemon=True),
                        threading.Thread(target=sender, daemon=True)]
        if self.view:
            self.threads.append(threading.Thread(target=checker, daemon=True))
        for t in self.threads:
            t.start()

    def shutdown(self):
        """Stop the threads, write out the buffer, submit what is pending once more."""
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
    """One sensor connection: one JSON reading per line."""

    def handle(self):
        gw = self.server.gw
        while True:
            line = self.rfile.readline(MAX_LINE)
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
    """TCP server with one thread per sensor connection."""
    allow_reuse_address = True
    daemon_threads = True


def main() -> None:
    """Read the options, start the gateway threads and the TCP server, run until Ctrl-C or SIGTERM."""
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--B", type=int, default=100, help="readings per batch")
    ap.add_argument("--T", type=float, default=30.0, help="max seconds the oldest reading waits")
    ap.add_argument("--listen-host", default="127.0.0.1", help="address the sensors connect to")
    ap.add_argument("--listen-port", type=int, default=9100, help="TCP port the sensors connect to")
    ap.add_argument("--outbox", default="outbox", help="folder for batch files, status files and state.json")
    ap.add_argument("--gateway-id", default="GW01", help="name written into every batch (the gateway id)")
    ap.add_argument("--submit", choices=["dry", "command"], default="dry",
                    help="dry = write batches only, command = run --submit-command for every batch")
    ap.add_argument("--submit-command", default=None,
                    help='template, e.g. "./submit.sh {file} {hash}" (no {..} = both appended)')
    ap.add_argument("--tx-reserve", type=int, default=layout.TX_RESERVE,
                    help="bytes of the transaction besides the metadata (plain ~300, contract ~1230)")
    ap.add_argument("--max-tries", type=int, default=5, help="failed submits before a batch goes to dead/")
    ap.add_argument("--retry", type=float, default=10.0, help="seconds between resends of pending batches")
    ap.add_argument("--kupo", default=os.environ.get("KUPO_URL"),
                    help="URL of Kupo, e.g. http://10.150.0.71:1442 (default: $KUPO_URL). With it, every submitted "
                         "batch is kept until its transaction is final and is sent again if it vanishes; "
                         "without it a batch counts as done when the submit command returns 0")
    ap.add_argument("--final-blocks", type=int, default=FINAL_BLOCKS,
                    help="blocks on top of a transaction until it is final (k)")
    ap.add_argument("--confirm-interval", type=float, default=CONFIRM_INTERVAL,
                    help="seconds between two looks at the batches that are not final yet")
    ap.add_argument("--missing-grace", type=float, default=MISSING_GRACE,
                    help="seconds a transaction may be missing in Kupo before its batch is sent again")
    ap.add_argument("--container", default=None, help="pool 1 container name for the node tip (default: docker ps)")
    ap.add_argument("--magic", type=int, default=reader.DEFAULT_MAGIC, help="network magic of the chain (net 1 = 42)")
    a = ap.parse_args()
    if a.B < 1 or a.T <= 0:
        ap.error("--B must be >= 1 and --T > 0")
    if a.max_tries < 1 or not 0 <= a.tx_reserve < layout.MAX_TX:
        ap.error("--max-tries must be >= 1 and --tx-reserve between 0 and %d" % layout.MAX_TX)
    if not layout.valid_id(a.gateway_id):
        ap.error("--gateway-id: use A-Z a-z 0-9 _ . -, 1-32 characters, not starting with 0x")
    if a.final_blocks < 1 or a.confirm_interval < 1 or a.missing_grace < 0:
        ap.error("--final-blocks must be >= 1, --confirm-interval >= 1 and --missing-grace >= 0")

    view = None
    if a.kupo:
        view = confirm.ChainView(reader.KupoClient(a.kupo), reader.DockerTip(a.container, a.magic))
    gw = Gateway(a.outbox, a.B, a.T, make_submit(a.submit, a.submit_command), a.gateway_id,
                 tx_reserve=a.tx_reserve, max_tries=a.max_tries, view=view, final_blocks=a.final_blocks,
                 missing_grace=a.missing_grace)
    if a.submit == "command" and not view:
        gw.log("WARNING no --kupo: batches are not followed until they are final (a replaced block loses them)")
    srv = Server((a.listen_host, a.listen_port), Handler)
    srv.gw = gw
    gw.start(a.retry, a.confirm_interval)

    def stop(*_):       # srv.shutdown() must not run in the thread that serves, so it gets its own thread
        threading.Thread(target=srv.shutdown).start()
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    gw.log("listening on %s:%d, B=%d T=%gs, outbox=%s, submit=%s, kupo=%s, final at %d blocks" %
           (a.listen_host, srv.server_address[1], a.B, a.T, a.outbox, a.submit, a.kupo or "none", a.final_blocks))
    srv.serve_forever()
    srv.server_close()
    gw.shutdown()


if __name__ == "__main__":
    main()
