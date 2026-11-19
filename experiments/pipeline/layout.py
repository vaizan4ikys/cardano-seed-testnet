"""Reading and batch layout for Cardano transaction metadata (label 1000).

Used by gateway.py (to build and size batches), reader.py / kupo_reader.py (to read them back) and calc_size.py.
It only holds pure functions and constants: no files, no network.

Everything is built from lists, integers and short text strings. There are no
maps below the label, so the order of the data cannot change on its way
through the chain and the hash of the file can always be rebuilt.
The exact bytes (compact JSON, field order) are what the batch hash is made from and what goes on the chain:
do not change this layout without raising VERSION.

  {"1000": [VERSION, gateway, batch_no, t0, [group, group, ...]]}
  group   = [sensor_id, kind_code, scale, [reading, reading, ...]]
  reading = [dt, value, seq]        dt = seconds after t0, value is an integer
"""
from __future__ import annotations

import hashlib
import json
import re
from typing import Any, Dict, List

Reading = Dict[str, Any]      # one clean reading: sensor_id, seq, ts, kind, value, scale

LABEL = 1000            # metadata label of our batches
VERSION = 1             # layout version, first field of the batch
KINDS = {"temperature": 1, "humidity": 2, "soil_moisture": 3}      # kind name -> code stored on the chain
KIND_NAMES = {v: k for k, v in KINDS.items()}
MAX_STR = 64            # Cardano limit for one text string in metadata
MAX_TX = 16384          # protocol limit for a whole transaction
# Room kept for everything in the transaction except the metadata. A plain payment
# transaction needs about 300 bytes (earlier test: 240 with one input). A transaction that
# also runs the contract needs about 1230 (script witness, redeemer, collateral, required
# signer, reference input; measured 1323-1325 bytes in total with 95 bytes of metadata).
# 1500 covers the contract case with some room. The gateway option --tx-reserve sets it.
TX_RESERVE = 1500
PLAIN_OVERHEAD = 300        # bytes besides the metadata: plain payment transaction
CONTRACT_OVERHEAD = 1230    # bytes besides the metadata: transaction that also runs the contract
AUX_WRAP = 8            # tag, map and label around the metadata value (approx.)
# Cardano metadata integers: -2^64 .. 2^64-1. The fields of a reading are kept much tighter.
INT_MIN, INT_MAX = -2 ** 64, 2 ** 64 - 1
LIMITS = {"seq": (0, 2 ** 32 - 1),
          "ts": (0, 2 ** 40 - 1),            # unix seconds
          "value": (-2 ** 53, 2 ** 53),      # exact in JavaScript numbers (web page)
          "scale": (1, 10 ** 6)}
ID_RE = re.compile(r"[A-Za-z0-9_.-]{1,32}")      # allowed sensor / gateway ids


def valid_id(s: Any) -> bool:
    """Sensor or gateway id: 1-32 of A-Z a-z 0-9 _ . - ; not starting with 0x (cardano-cli would
    turn such a string into a byte string)."""
    return (isinstance(s, str) and ID_RE.fullmatch(s) is not None
            and not s.lower().startswith("0x"))


def _is_int(x: Any) -> bool:
    """True for integers, but not for True/False (bool is a subclass of int)."""
    return isinstance(x, int) and not isinstance(x, bool)


def parse_reading(d: Any) -> Reading:
    """Check one reading received from a sensor; return a clean dict or raise ValueError."""
    if not isinstance(d, dict):
        raise ValueError("not an object")
    if not valid_id(d.get("sensor_id")):
        raise ValueError("bad sensor_id")
    if d.get("kind") not in KINDS:
        raise ValueError("bad kind")
    for k, (lo, hi) in LIMITS.items():
        v = d.get(k)
        if not _is_int(v):
            raise ValueError("%s must be an integer" % k)
        if not lo <= v <= hi:
            raise ValueError("%s out of range" % k)
    return {k: d[k] for k in ("sensor_id", "seq", "ts", "kind", "value", "scale")}


def build_batch(gateway_id: str, batch_no: int, readings: List[Reading]) -> Dict[str, Any]:
    """readings: list of clean dicts (see parse_reading). Returns the metadata object."""
    t0 = min(r["ts"] for r in readings)
    groups = {}
    for r in readings:
        key = (r["sensor_id"], KINDS[r["kind"]], r["scale"])
        groups.setdefault(key, []).append([r["ts"] - t0, r["value"], r["seq"]])
    body = [[s, k, sc, rows] for (s, k, sc), rows in groups.items()]
    return {str(LABEL): [VERSION, gateway_id, batch_no, t0, body]}


def decode_batch(obj: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Metadata object -> flat list of readings."""
    _, gw, batch_no, t0, groups = obj[str(LABEL)]
    out = []
    for sensor, kind, scale, rows in groups:
        for dt, value, seq in rows:
            out.append({"sensor": sensor, "kind": KIND_NAMES[kind], "scale": scale,
                        "ts": t0 + dt, "value": value, "seq": seq})
    return out


def dump(obj: Any) -> bytes:
    """The exact bytes of the metadata JSON file: compact, ASCII, no newline at the end."""
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=True).encode("ascii")


def batch_hash(data: bytes) -> str:
    """Batch hash rule: sha256 of the exact bytes of the metadata JSON file."""
    return hashlib.sha256(data).hexdigest()


def _head(n: int) -> int:
    """Bytes of a CBOR head (type and length/number) for the value n."""
    return 1 if n < 24 else 2 if n < 256 else 3 if n < 65536 else 5 if n < 2 ** 32 else 9


def cbor_len(x: Any) -> int:
    """Size in bytes of x as CBOR (ints, text, lists, maps)."""
    if _is_int(x):
        return _head(x if x >= 0 else -1 - x)
    if isinstance(x, str):
        n = len(x.encode())
        return _head(n) + n
    if isinstance(x, list):
        return _head(len(x)) + sum(cbor_len(i) for i in x)
    if isinstance(x, dict):
        return _head(len(x)) + sum(cbor_len(k) + cbor_len(v) for k, v in x.items())
    raise ValueError("type not allowed in metadata: %r" % type(x))


def check_metadata(x: Any) -> None:
    """Raise ValueError for floats, bools, None, text longer than 64 bytes or integers out of range."""
    if _is_int(x):
        if not INT_MIN <= x <= INT_MAX:
            raise ValueError("integer outside the metadata range")
        return
    if isinstance(x, str):
        if len(x.encode()) > MAX_STR:
            raise ValueError("string longer than 64 bytes")
    elif isinstance(x, list):
        for i in x:
            check_metadata(i)
    elif isinstance(x, dict):
        for k, v in x.items():
            check_metadata(k)
            check_metadata(v)
    else:
        raise ValueError("type not allowed in metadata: %r" % type(x))


def tx_estimate(obj: Dict[str, Any], reserve: int = TX_RESERVE) -> int:
    """Estimated size of the whole transaction that carries this metadata."""
    return AUX_WRAP + 3 + cbor_len(obj[str(LABEL)]) + reserve


def fits(obj: Dict[str, Any], reserve: int = TX_RESERVE) -> bool:
    """True if the transaction that carries this metadata stays within MAX_TX."""
    return tx_estimate(obj, reserve) <= MAX_TX


def fit_chunks(readings: List[Reading], gateway_id: str, reserve: int = TX_RESERVE) -> List[List[Reading]]:
    """Split a list of readings (in order) until each part fits into one transaction."""
    if len(readings) > 1 and not fits(build_batch(gateway_id, 0, readings), reserve):
        h = len(readings) // 2
        return (fit_chunks(readings[:h], gateway_id, reserve)
                + fit_chunks(readings[h:], gateway_id, reserve))
    return [readings]
