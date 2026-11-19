"""Reader: keeps the state of the web page in memory, rebuilt from Kupo.

Kupo is the database. This module has no files and no SQLite. After a restart the state is read again from Kupo.

What it does
  poll_once()  asks Kupo (about every 2 s): new transactions (/matches?created_after=<cursor - window>), the metadata of
               every transaction it has not seen, and the block header hash of the batches that are not final yet.
               The window (default 300 slots) is read again on every poll, so a rollback is noticed.
  poll_tip()   asks the node for its tip (block number, slot, hash). The block number of a batch is the tip block at
               the moment the batch was first seen (the batch was just included, so this is right to about one
               block). Depth = tip block - batch block + 1. Final at depth >= final_depth (default 60 = k).
               A batch that was already on the chain when the server started has no first-seen record: its depth is
               ESTIMATED from the slots and marked 'estimate'.
  state()      everything the page shows, as plain data (lists, dicts, numbers, strings).

Identity: the gateway id inside the metadata is only what the sender wrote. The real identity is the address of
output #0 of the transaction (the change output at the gateway wallet). A table (gateways.json, name -> address) gives
the name of that address; a batch whose declared id does not match the name of its signer is flagged.

Clocks: the sensor timestamps come from the sensor machine. "Silent" is decided only with the server clock: the
time since this server last saw a NEW reading arrive from the chain. The age by the sensor clock is also given,
but only for information.

Used by server.py (nothing to run here). Input: Kupo over HTTP, the node tip from `docker exec ... cardano-cli`,
gateways.json. Output: the dict returned by Reader.state() (the JSON of /api/state: its field names are the contract
with page.html). Nothing is written to disk.
"""
from __future__ import annotations

import datetime
import json
import math
import subprocess
import threading
import time
import urllib.error
import urllib.request
from typing import Any, Callable, Dict, List, Optional, Tuple

import kupo_reader
import layout

RECEIPT_HEX = "52454345495054"          # "RECEIPT" as hex (asset name of the receipt token)
UNITS = {"temperature": "°C", "humidity": "%", "soil_moisture": "%"}
# kind -> (lowest, highest) normal value; outside = "out of range" (server.py --limits changes them)
DEFAULT_LIMITS = {"temperature": (-40.0, 60.0), "humidity": (0.0, 100.0), "soil_moisture": (0.0, 100.0)}
LIVE_LAG_SLOTS = 30          # a batch first seen this close to the tip is "just included"
TIP_STALE_S = 10             # a tip older than this is not used as the first-seen block
DOCKER_TIMEOUT_S = 20        # seconds for one docker command (tip query, registry files)
POOL1_NAME_PART = "-Pool-1-"  # part of the name of pool 1's container
DEFAULT_MAGIC = 42           # network magic of net 1
DEFAULT_REGISTRY_DIR = "/tmp/p0n"   # folder in pool 1's container with admin.addr, policy.id, token.hex
FALLBACK_BLOCKS_PER_SLOT = 0.2      # used for depth estimates while the tip has no usable ratio yet
MIN_LOOP_SLEEP_S = 0.2       # run_loop never spins faster than this


def default_log(msg: str) -> None:
    """Print one line with the time of day."""
    print("%s %s" % (datetime.datetime.now().strftime("%H:%M:%S"), msg), flush=True)


def parse_limits(text: Optional[str]) -> Dict[str, Tuple[float, float]]:
    """'temperature=-40:60,humidity=0:100' -> dict kind -> (lo, hi). Starts from the defaults."""
    out = dict(DEFAULT_LIMITS)
    for part in filter(None, (text or "").split(",")):
        kind, rng = part.split("=")
        lo, hi = rng.split(":")
        if kind not in layout.KINDS:
            raise ValueError("unknown kind: %s" % kind)
        out[kind] = (float(lo), float(hi))
    return out


def load_gateways(path: str) -> Dict[str, str]:
    """gateways.json: {"GW01": "addr_test1...", ...}. Returns {} if the file is missing."""
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return {str(k): str(v) for k, v in data.items()}


# ---------------------------------------------------------------- the layout check

def _is_int(x: Any) -> bool:
    """True for integers, but not for True/False."""
    return isinstance(x, int) and not isinstance(x, bool)


def parse_our_batch(obj: Dict[str, Any]) -> Dict[str, Any]:
    """Metadata object of label 1000 -> dict (gateway, batch_no, t0, readings).
    ValueError if it is not our layout."""
    v = obj.get(str(layout.LABEL))
    if not isinstance(v, list) or len(v) != 5:
        raise ValueError("label 1000 is not a list of 5")
    version, gw, batch_no, t0, groups = v
    if version != layout.VERSION or not isinstance(gw, str) or not _is_int(batch_no) or not _is_int(t0):
        raise ValueError("header fields do not match")
    if not isinstance(groups, list):
        raise ValueError("groups is not a list")
    for g in groups:
        if not isinstance(g, list) or len(g) != 4:
            raise ValueError("bad group")
        sensor, kind, scale, rows = g
        if not isinstance(sensor, str) or kind not in layout.KIND_NAMES or not _is_int(kind):
            raise ValueError("bad sensor or kind")
        if not _is_int(scale) or scale < 1 or not isinstance(rows, list):
            raise ValueError("bad scale or rows")
        for r in rows:
            if not isinstance(r, list) or len(r) != 3 or not all(_is_int(x) for x in r):
                raise ValueError("bad reading")
    return {"gateway": gw, "batch_no": batch_no, "t0": t0, "readings": layout.decode_batch(obj)}


# ---------------------------------------------------------------- Kupo and node access

def parse_prometheus(text: str) -> Dict[str, float]:
    """Prometheus text ("name value" per line, # = comment) -> {name: value}."""
    out = {}
    for line in text.splitlines():
        if line and not line.startswith("#"):
            parts = line.split()
            if len(parts) == 2:
                try:
                    out[parts[0]] = float(parts[1])
                except ValueError:
                    pass
    return out


def parse_health(text: str) -> Dict[str, Any]:
    """Kupo's /health answer. Without an Accept header it is JSON, with Accept: text/plain it is Prometheus text."""
    if text.lstrip().startswith("{"):
        d = json.loads(text)
        return {"checkpoint": int(d.get("most_recent_checkpoint") or 0),
                "node_tip": int(d.get("most_recent_node_tip") or 0),
                "connected": d.get("connection_status") == "connected",
                "synced": float(d.get("network_synchronization") or 0)}
    m = parse_prometheus(text)
    return {"checkpoint": int(m.get("kupo_most_recent_checkpoint", 0)),
            "node_tip": int(m.get("kupo_most_recent_node_tip", 0)),
            "connected": m.get("kupo_connection_status", 0) >= 1,
            "synced": m.get("kupo_network_synchronization", 0)}


class KupoClient(kupo_reader.Kupo):
    """kupo_reader.Kupo plus /health and the raw /matches list."""

    def health(self) -> Dict[str, Any]:
        """{'checkpoint': slot, 'node_tip': slot, 'connected': bool, 'synced': float}.
        Raises if Kupo cannot be reached."""
        try:
            with urllib.request.urlopen(self.base + "/health", timeout=self.timeout) as r:
                text = r.read().decode()
        except urllib.error.HTTPError as e:      # Kupo answers 503 without a node connection; the body is still there
            text = e.read().decode()
        return parse_health(text)

    def matches(self, after_slot: int) -> List[Dict[str, Any]]:
        """Raw /matches list (all outputs created from after_slot on), oldest first."""
        data, _ = self._get("/matches", created_after=max(after_slot, 1), order="oldest_first")
        return data


class DockerTip:
    """Node tip from cardano-cli inside the pool 1 container: get() -> {'block', 'slot', 'hash'}."""

    def __init__(self, container: Optional[str] = None, magic: int = DEFAULT_MAGIC, timeout: int = DOCKER_TIMEOUT_S):
        self.container, self.magic, self.timeout = container, magic, timeout

    def _find(self) -> str:
        """Name of pool 1's container (found with docker ps)."""
        r = subprocess.run(["docker", "ps", "--format", "{{.Names}}"],
                           capture_output=True, text=True, timeout=self.timeout)
        for name in r.stdout.split():
            if POOL1_NAME_PART in name:
                return name
        raise RuntimeError("no pool 1 container found")

    def get(self) -> Dict[str, Any]:
        """Ask the node for its tip. Raises RuntimeError when docker or cardano-cli fails."""
        if not self.container:
            self.container = self._find()
        cmd = ["docker", "exec", self.container, "cardano-cli", "conway", "query", "tip",
               "--socket-path", "/node.socket", "--testnet-magic", str(self.magic)]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=self.timeout)
        except subprocess.TimeoutExpired:
            raise RuntimeError("cardano-cli tip timed out")
        if r.returncode != 0:
            self.container = None          # look again next time
            raise RuntimeError("tip query failed: %s" % (r.stderr.strip()[-200:] or r.returncode))
        d = json.loads(r.stdout)
        return {"block": int(d["block"]), "slot": int(d["slot"]), "hash": d["hash"]}


# ---------------------------------------------------------------- the registry (who may send)

_B32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"      # the 32 characters of the bech32 alphabet


def address_key_hash(addr: str) -> Optional[str]:
    """bech32 Cardano address -> payment key hash (28 bytes, hex), or None.
    The checksum is not verified (the address comes from our own file)."""
    try:
        _, data = addr.rsplit("1", 1)
        vals = [_B32.index(c) for c in data[:-6]]
        acc, bits, out = 0, 0, []
        for v in vals:
            acc = (acc << 5) | v
            bits += 5
            while bits >= 8:
                bits -= 8
                out.append((acc >> bits) & 0xFF)
        return bytes(out[1:29]).hex() if len(out) >= 29 else None
    except (ValueError, AttributeError):
        return None


def parse_key_list(cbor_hex: str) -> List[str]:
    """The registry datum (CBOR: a list of 28-byte strings, definite or indefinite) -> [hex, ...].
    Raises ValueError on anything else."""
    b = bytes.fromhex(cbor_hex)
    pos = 0

    def head():
        """Read one CBOR head at pos: (major type, length or number; None = indefinite length)."""
        nonlocal pos
        ib = b[pos]
        pos += 1
        major, info = ib >> 5, ib & 31
        if info < 24:
            return major, info
        if info in (24, 25, 26, 27):
            n = 1 << (info - 24)
            v = int.from_bytes(b[pos:pos + n], "big")
            pos += n
            return major, v
        if info == 31:
            return major, None
        raise ValueError("bad CBOR")

    if b and b[0] >> 5 == 6:                  # a constructor tag around the list: skip it
        head()
    major, n = head()
    if major != 4:
        raise ValueError("registry datum is not a list")
    keys = []
    while True:
        if n is None and b[pos] == 0xFF:
            break
        if n is not None and len(keys) >= n:
            break
        major, ln = head()
        if major != 2 or ln is None:
            raise ValueError("registry list item is not a byte string")
        keys.append(b[pos:pos + ln].hex())
        pos += ln
    return keys


class Registry:
    """Reads the gateway list from the chain through Kupo: the one coin at the administrator address that holds
    the registry token."""

    def __init__(self, kupo: kupo_reader.Kupo, directory: str = DEFAULT_REGISTRY_DIR,
                 container: Optional[str] = None, clock: Callable[[], float] = time.time,
                 log: Callable[[str], None] = default_log):
        self.kupo, self.directory, self.container, self.clock, self.log = kupo, directory, container, clock, log
        self.ident = None                    # (address, "policy.token")
        self.keys, self.last_ok, self.error = None, None, "not asked yet"

    def _identity(self) -> Tuple[str, str]:
        """(administrator address, "policy.token") of the registry coin, read once from the files in the container."""
        if self.ident:
            return self.ident
        if not self.container:
            self.container = DockerTip()._find()
        read_files = "cd %s && for f in admin.addr policy.id token.hex; do cat $f; echo; done" % self.directory
        r = subprocess.run(["docker", "exec", self.container, "sh", "-c", read_files],
                           capture_output=True, text=True, timeout=DOCKER_TIMEOUT_S)
        parts = r.stdout.split()
        if r.returncode != 0 or len(parts) != 3:
            raise RuntimeError("registry files not found in %s" % self.directory)
        self.ident = (parts[0], parts[1] + "." + parts[2])
        return self.ident

    def poll(self) -> bool:
        """Read the registry coin and its datum from Kupo. Returns True on success; an error is kept in self.error."""
        try:
            addr, asset = self._identity()
            data, _ = self.kupo._get("/matches/" + addr + "?unspent")
            hits = [m for m in data if asset in (m.get("value", {}).get("assets") or {})]
            if len(hits) != 1:
                raise RuntimeError("%d registry coins found (expected 1)" % len(hits))
            h = hits[0].get("datum_hash")
            if not h:
                raise RuntimeError("registry coin has no datum")
            d, _ = self.kupo._get("/datums/" + h)
            self.keys, self.last_ok, self.error = set(parse_key_list(d["datum"])), self.clock(), None
        except Exception as e:
            if self.error is None:
                self.log("registry unreadable: %s" % e)
            self.error = str(e)
            return False
        return True

    def info(self) -> Dict[str, Any]:
        """The 'registry' part of the page state."""
        return {"known": self.keys is not None, "size": len(self.keys) if self.keys is not None else None,
                "error": self.error, "age": None if self.last_ok is None else round(self.clock() - self.last_ok, 1)}

    def approved(self, address):
        """True / False, or None if the list is not known (yet) or the address has no key hash."""
        if self.keys is None:
            return None
        h = address_key_hash(address)
        return None if h is None else h in self.keys


# ---------------------------------------------------------------- the reader

class Reader:
    """The state of the page: every batch found on the chain, the node tip, Kupo's health. Thread safe (self.lock)."""

    def __init__(self, kupo: KupoClient, tip_source: DockerTip, gateways: Optional[Dict[str, str]] = None,
                 final_depth: int = 60, window: int = 300, silent_after: float = 30,
                 limits: Optional[Dict[str, Tuple[float, float]]] = None, receipt_policy: Optional[str] = None,
                 clock: Callable[[], float] = time.time, log: Callable[[str], None] = default_log,
                 kupo_url: str = "", registry: Optional[Registry] = None):
        self.kupo, self.tip_source = kupo, tip_source
        self.registry = registry                                # Registry or None
        self.gateways = dict(gateways or {})                   # name -> address
        self.names = {a: n for n, a in self.gateways.items()}  # address -> name
        self.final_depth, self.window, self.silent_after = final_depth, window, silent_after
        self.limits = limits or dict(DEFAULT_LIMITS)
        self.receipt_policy, self.clock, self.log, self.kupo_url = receipt_policy, clock, log, kupo_url
        self.lock = threading.RLock()
        self.batches = {}          # txid -> record (insertion order = oldest first)
        self.foreign = {}          # txid -> slot of transactions that are not our batches
        self.skipped = set()       # txids with label 1000 that is not our layout
        self.logged_skip = False
        self.cursor = 0            # highest slot of a transaction seen
        self.first_poll_done = False
        self.arrival = {}          # (sensor, kind) -> server time of the last NEW reading
        self.tip, self.tip_time, self.tip_error = None, None, None
        self.kupo_state = {"ok": False, "error": "not asked yet", "last_ok": None, "health": None}
        self.started = clock()
        self.rev = 0               # grows when the set of live batches changes
        self._cache = (None, None)

    # ----------------------------------------------------------- tip

    def poll_tip(self) -> bool:
        """Ask the node for its tip. Returns True on success; an error is kept for the page."""
        try:
            t = self.tip_source.get()
        except Exception as e:
            with self.lock:
                self.tip_error = str(e)
            return False
        with self.lock:
            self.tip, self.tip_time, self.tip_error = t, self.clock(), None
            for rec in self.batches.values():       # batches found before the first tip was known
                if rec["block"] is None:
                    rec["block"] = self._estimated_block(rec["slot"])
            self._latch()
        return True

    def _blocks_per_slot(self) -> float:
        """Average number of blocks per slot on this chain (from the tip), for depth estimates."""
        t = self.tip
        if t and t["slot"] > 0 and t["block"] > 0:
            return t["block"] / float(t["slot"])
        return FALLBACK_BLOCKS_PER_SLOT

    def _estimated_block(self, slot: int) -> Optional[int]:
        """Block number of a batch in `slot`, guessed from the tip and the blocks-per-slot ratio."""
        t = self.tip
        if not t:
            return None
        back = int(round(max(t["slot"] - slot, 0) * self._blocks_per_slot()))
        return max(t["block"] - back, 1)

    def _first_seen_block(self, slot: int) -> Tuple[Optional[int], bool]:
        """(block, estimate) for a batch that has just been found."""
        t = self.tip
        if not t:
            return None, True
        fresh = self.tip_time is not None and self.clock() - self.tip_time <= TIP_STALE_S
        if self.first_poll_done and fresh and t["slot"] - slot <= LIVE_LAG_SLOTS:
            # a tip that is older than the batch means the batch is in a newer block than the tip
            return (t["block"] + 1 if t["slot"] < slot else t["block"]), False
        return self._estimated_block(slot), True

    def _depth(self, rec: Dict[str, Any]) -> Optional[int]:
        """Blocks on top of the batch (1 = in the tip block); None if rolled back or not known."""
        if rec["rolled_back"] or rec["block"] is None or self.tip is None:
            return None
        return max(self.tip["block"] - rec["block"] + 1, 1)

    def _latch(self):
        """Mark batches that reached final_depth as final (and keep them final)."""
        for rec in self.batches.values():
            if not rec["rolled_back"] and not rec["final"]:
                d = self._depth(rec)
                if d is not None and d >= self.final_depth:
                    rec["final"] = True

    # ----------------------------------------------------------- Kupo

    def _kupo_failed(self, e: Exception) -> None:
        with self.lock:
            if self.kupo_state["ok"] or self.kupo_state["error"] is None:
                self.log("indexer unreachable: %s" % e)
            self.kupo_state["ok"], self.kupo_state["error"] = False, str(e)

    def poll_once(self):
        """One round with Kupo. Returns True if Kupo answered. On a failure the old data stays."""
        try:
            health = self.kupo.health()
            after = max(self.cursor - self.window, 0)
            txs = self._group(self.kupo.matches(after))
            listed = set()
            for tx in txs:
                listed.add(tx["txid"])
                self._handle(tx)
            self._recheck(listed, health["checkpoint"])
        except Exception as e:      # network, HTTP, bad JSON: keep what we have
            self._kupo_failed(e)
            return False
        with self.lock:
            if txs:
                self.cursor = max(self.cursor, max(t["slot"] for t in txs))
            self.first_poll_done = True
            self.kupo_state = {"ok": True, "error": None, "last_ok": self.clock(), "health": health}
            self._latch()
        return True

    @staticmethod
    def _group(matches):
        """Raw Kupo matches -> one entry per transaction (oldest first): slot, txid, header hash, output #0."""
        order, by = [], {}
        for m in matches:
            key = (m["created_at"]["slot_no"], m["transaction_id"])
            if key not in by:
                by[key] = {"slot": key[0], "txid": key[1], "header": m["created_at"].get("header_hash"), "out0": None}
                order.append(by[key])
            if m.get("output_index") == 0:
                by[key]["out0"] = m
        return order

    def _receipts(self, out0: Optional[Dict[str, Any]]) -> Optional[int]:
        """Amount of the RECEIPT token in output #0 (None if there is none)."""
        if not out0:
            return None
        for asset, qty in (out0.get("value", {}).get("assets") or {}).items():
            policy, _, name = asset.partition(".")
            if name == RECEIPT_HEX and (not self.receipt_policy or policy == self.receipt_policy):
                return int(qty)
        return None

    def _handle(self, tx: Dict[str, Any]) -> None:
        """Take one transaction from the Kupo list: new batch, known batch (check for a rollback) or foreign."""
        slot, txid, header = tx["slot"], tx["txid"], tx["header"]
        with self.lock:
            rec = self.batches.get(txid)
            if rec is not None:
                if rec["final"]:
                    return
                if rec["rolled_back"] or rec["slot"] != slot or rec["header"] != header:
                    self._reincluded(rec, slot, header)
                return
            if self.foreign.get(txid) == slot:
                return
        obj, h, header2 = self.kupo.batch(slot, txid)       # outside the lock: network
        with self.lock:
            if obj is None:
                self.foreign[txid] = slot                     # no metadata under label 1000
                return
            if header2 and header and header2 != header:
                return                                        # the chain moved between the two questions; next poll
            try:
                parsed = parse_our_batch(obj)
            except (ValueError, KeyError, TypeError) as e:
                self.foreign[txid] = slot
                self.skipped.add(txid)
                if not self.logged_skip:
                    self.logged_skip = True
                    self.log("skipping a label-1000 transaction that is not our layout (%s...): %s; "
                             "later ones are only counted" % (txid[:12], e))
                return
            block, estimate = self._first_seen_block(slot)
            out0 = tx["out0"]
            now = self.clock()
            rec = {"txid": txid, "slot": slot, "header": header or header2, "hash": layout.batch_hash(layout.dump(obj)),
                   "declared": parsed["gateway"], "batch_no": parsed["batch_no"], "t0": parsed["t0"],
                   "readings": parsed["readings"], "signer": out0["address"] if out0 else None,
                   "receipts": self._receipts(out0), "block": block, "estimate": estimate,
                   "seen_at": now, "rolled_back": False, "final": False, "reorgs": 0}
            self.batches[txid] = rec
            for key in {(r["sensor"], r["kind"]) for r in rec["readings"]}:
                self.arrival[key] = now
            self.rev += 1
            self._latch()

    def _reincluded(self, rec, slot, header):
        """The batch is on the chain again (or in another block) after a rollback: count the depth again."""
        was = "rolled back" if rec["rolled_back"] else "moved to another block"
        if slot != rec["slot"]:         # a new slot is recent: count the depth again. The same slot keeps its block.
            rec["block"], rec["estimate"] = self._first_seen_block(slot)
        rec.update({"slot": slot, "header": header, "rolled_back": False})
        rec["reorgs"] += 1
        self.rev += 1
        self.log("batch %s... was %s; it is in a block again" % (rec["txid"][:12], was))

    def _recheck(self, listed, checkpoint):
        """Ask again for the header hash of every batch that is not final and was not in the list just read."""
        with self.lock:
            todo = [r for r in self.batches.values()
                    if not r["final"] and not r["rolled_back"] and r["txid"] not in listed and r["slot"] <= checkpoint]
        for rec in todo:
            obj, _, header = self.kupo.batch(rec["slot"], rec["txid"])
            with self.lock:
                if rec["final"] or rec["rolled_back"]:
                    continue
                if obj is None:
                    rec["rolled_back"] = True
                    self.rev += 1
                    self.log("batch %s... (slot %d) is no longer on the chain: rolled back"
                             % (rec["txid"][:12], rec["slot"]))
                elif header and header != rec["header"]:
                    self._reincluded(rec, rec["slot"], header)

    # ----------------------------------------------------------- what the page shows

    def _signer_name(self, addr: Optional[str]) -> Optional[str]:
        """Name of the gateway that owns this wallet address (None if unknown)."""
        return self.names.get(addr) if addr else None

    def _warnings(self, rec: Dict[str, Any]) -> List[str]:
        """Texts for the page when the signer is unknown or differs from the gateway id inside the batch."""
        w = []
        name = self._signer_name(rec["signer"])
        if rec["signer"] is None:
            w.append("signer unknown (no output #0 found)")
        elif name is None:
            w.append("unknown signer")
        elif name != rec["declared"]:
            w.append("identity mismatch: metadata says %s, signer is %s" % (rec["declared"], name))
        return w

    def _sensor_table(self):
        """Per (sensor, kind): all points of the live batches, oldest first. Rebuilt only when the batches change."""
        if self._cache[0] == self.rev:
            return self._cache[1]
        table = {}
        for rec in self.batches.values():
            if rec["rolled_back"]:
                continue
            for r in rec["readings"]:
                s = table.setdefault((r["sensor"], r["kind"]), {"scale": r["scale"], "points": {}})
                s["scale"] = r["scale"]
                s["gateway"] = self._signer_name(rec["signer"]) or rec["declared"]   # the newest batch wins
                s["points"][(r["ts"], r["seq"], r["value"])] = 1
        for s in table.values():
            s["points"] = sorted(s["points"])
        self._cache = (self.rev, table)
        return table

    def _in_range(self, kind: str, value: float) -> bool:
        lo, hi = self.limits.get(kind, (-1e18, 1e18))
        return lo <= value <= hi

    def _batch_status(self, rec: Dict[str, Any]) -> str:
        """Text shown on the page: "rolled back", "final" or "in a block"."""
        if rec["rolled_back"]:
            return "rolled back"
        if rec["final"]:
            return "final"
        return "in a block"

    def _batch_row(self, rec: Dict[str, Any], depth: Optional[int], now: float) -> Dict[str, Any]:
        """One batch as the page shows it (field names are the contract with page.html)."""
        return {
            "txid": rec["txid"], "slot": rec["slot"], "header": rec["header"], "hash": rec["hash"],
            "declared": rec["declared"], "batch_no": rec["batch_no"], "signer": rec["signer"],
            "signer_name": self._signer_name(rec["signer"]), "receipts": rec["receipts"],
            "readings": len(rec["readings"]), "block": rec["block"], "depth": depth,
            "progress": None if depth is None else min(depth / float(self.final_depth), 1.0),
            "status": self._batch_status(rec), "estimate": rec["estimate"], "reorgs": rec["reorgs"],
            "seen_age": round(now - rec["seen_at"], 1), "warnings": self._warnings(rec)}

    def state(self, max_batches: int = 100, max_points: int = 200) -> Dict[str, Any]:
        """Everything the page shows, as plain data: the answer of /api/state.
        max_batches = newest batches listed, max_points = newest points per sensor."""
        with self.lock:
            now = self.clock()
            tip = dict(self.tip) if self.tip else None
            if tip:
                tip["age"] = round(now - self.tip_time, 1)
            batches = []
            counts = {"batches": 0, "final": 0, "rolled_back": 0, "estimate": 0, "readings": 0,
                      "final_readings": 0}
            per_gw = {}                 # signer address -> totals over its batches
            for rec in reversed(list(self.batches.values())):          # newest first
                counts["batches"] += 1
                if rec["rolled_back"]:
                    counts["rolled_back"] += 1
                else:
                    counts["readings"] += len(rec["readings"])
                    counts["final"] += 1 if rec["final"] else 0
                    counts["final_readings"] += len(rec["readings"]) if rec["final"] else 0
                    counts["estimate"] += 1 if rec["estimate"] else 0
                    g = per_gw.setdefault(rec["signer"], {"batches": 0, "readings": 0, "last_seen": 0,
                                                          "last_slot": 0, "receipts": None})
                    g["batches"] += 1
                    g["readings"] += len(rec["readings"])
                    if rec["seen_at"] >= g["last_seen"]:
                        g["last_seen"] = rec["seen_at"]
                    if rec["slot"] >= g["last_slot"]:
                        g["last_slot"] = rec["slot"]
                        g["receipts"] = rec["receipts"]
                if len(batches) < max_batches:
                    batches.append(self._batch_row(rec, self._depth(rec), now))
            gws = []
            for name, addr in self.gateways.items():             # known gateways first, in file order
                gws.append(self._gateway_row(name, addr, per_gw.pop(addr, None), now))
            for addr, g in per_gw.items():                       # then signers that are not in gateways.json
                gws.append(self._gateway_row(None, addr, g, now))
            sensors = []
            for (sensor, kind), s in sorted(self._sensor_table().items()):
                sensors.append(self._sensor_row(sensor, kind, s, now, max_points))
            ks = dict(self.kupo_state)
            ks["url"] = self.kupo_url
            ks["last_ok_age"] = None if ks["last_ok"] is None else round(now - ks["last_ok"], 1)
            del ks["last_ok"]
            registry = (self.registry.info() if self.registry
                        else {"known": False, "size": None, "error": "not configured", "age": None})
            counts = dict(counts, skipped_foreign=len(self.skipped),
                          other_transactions=len(self.foreign) - len(self.skipped), sensors=len(sensors))
            return {"server_time": now, "started": self.started, "tip": tip, "tip_error": self.tip_error,
                    "kupo": ks, "final_depth": self.final_depth, "silent_after": self.silent_after,
                    "limits": {k: list(v) for k, v in self.limits.items()},
                    "counts": counts, "registry": registry,
                    "gateways": gws, "batches": batches, "sensors": sensors}

    def _gateway_row(self, name: Optional[str], addr: str, g: Optional[Dict[str, Any]],
                     now: float) -> Dict[str, Any]:
        """One gateway as the page shows it; g = its totals (None if it has sent no batch)."""
        return {"name": name, "address": addr, "batches": g["batches"] if g else 0,
                "readings": g["readings"] if g else 0,
                "last_batch_age": round(now - g["last_seen"], 1) if g else None,
                "last_slot": g["last_slot"] if g else None, "receipts": g["receipts"] if g else None,
                "approved": self.registry.approved(addr) if self.registry else None}

    def _sensor_row(self, sensor: str, kind: str, s: Dict[str, Any], now: float,
                    max_points: int) -> Dict[str, Any]:
        """One sensor as the page shows it. Points are [ts, value, out-of-range flag 0/1, seq]."""
        pts = s["points"]
        scale = s["scale"]
        digits = len(str(scale - 1)) if scale > 1 else 0         # decimals to show: scale 100 -> 2
        ts, seq, raw = pts[-1]
        value = raw / float(scale)
        recent = [[p[0], round(p[2] / float(scale), digits),
                   0 if self._in_range(kind, p[2] / float(scale)) else 1, p[1]]
                  for p in pts[-max_points:]]
        out_count = sum(1 for p in pts if not self._in_range(kind, p[2] / float(scale)))
        arrived = self.arrival.get((sensor, kind), self.started)
        since = now - arrived
        return {"sensor": sensor, "kind": kind, "gateway": s.get("gateway"), "unit": UNITS.get(kind, ""),
                "scale": scale, "latest": round(value, digits), "text": "%.*f" % (digits, value),
                "last_ts": ts, "count": len(pts),
                "out_of_range": not self._in_range(kind, value), "out_of_range_count": out_count,
                "seen_age": round(since, 1), "silent": since > self.silent_after,
                "age_sensor_clock": round(now - ts, 1), "silent_sensor_clock": now - ts > self.silent_after,
                "points": recent}


# ---------------------------------------------------------------- threads

def run_loop(fn: Callable[[], Any], interval: float, stop: threading.Event) -> None:
    """Call fn() every `interval` seconds until the stop event is set (an error in fn never ends the loop)."""
    while not stop.is_set():
        started = time.time()
        try:
            fn()
        except Exception as e:      # should not happen; keep going
            default_log("reader error: %r" % (e,))
        stop.wait(max(interval - (time.time() - started), MIN_LOOP_SLEEP_S))
