#!/usr/bin/env python3
"""How many readings fit into one transaction? Sizes are CBOR bytes of the metadata value.

  python3 calc_size.py            table for the layout of layout.py and for the older sample layout

Prints a table (sizes for 1 ... 1500 readings per batch) and the largest batch that fits into one transaction.
Uses made-up readings only; nothing is read or written.
"""
from __future__ import annotations

import random
from typing import Any, Callable, Dict, List, Tuple

import layout

SENSORS = 10          # sensors that report into one batch
SEQ_START = 1000      # typical sequence number after a while (3 bytes in CBOR)
# kind: (lowest raw value, highest raw value, scale) of the made-up readings
RANGE = {"temperature": (1000, 3500, 100), "humidity": (300, 900, 10), "soil_moisture": (100, 600, 10)}
KINDS = list(RANGE)
PREFIXES = ["AGRI", "ATMO", "SOIL"]       # sensor ids look like AGRI_001, ATMO_002, SOIL_003, ...
FIRST_TS = 1760000000                      # time of the first made-up reading
BATCH_SIZES = (1, 10, 50, 100, 200, 500, 1000, 1500)      # rows of the table
MAX_SEARCH = 20000    # upper end of the search for the largest batch that fits


def make_readings(n: int, sensors: int = SENSORS, seed: int = 1, span: int = 20) -> List[Dict[str, Any]]:
    """n readings from `sensors` sensors, spread over `span` seconds."""
    rng = random.Random(seed)
    seq = {}
    out = []
    for i in range(n):
        s = i % sensors
        kind = KINDS[s % 3]
        lo, hi, scale = RANGE[kind]
        seq[s] = seq.get(s, SEQ_START) + 1
        out.append({"sensor_id": "%s_%03d" % (PREFIXES[s % 3], s + 1), "seq": seq[s],
                    "ts": FIRST_TS + i * span // max(n, 1),
                    "kind": kind, "value": rng.randint(lo, hi), "scale": scale})
    return out


def old_style(r: Dict[str, Any]) -> Dict[str, Any]:
    """One reading as in the older sample: a map with names, unit and scale for every reading."""
    unit = {"temperature": "C", "humidity": "%", "soil_moisture": "%"}[r["kind"]]
    return {"schema_version": 1, "sensor_id": r["sensor_id"], "timestamp": "2026-10-16T13:30:00Z",
            "measurements": {r["kind"]: {"value": r["value"], "scale": r["scale"], "unit": unit}}}


def new_size(n: int, sensors: int = SENSORS) -> Tuple[int, int, Dict[str, Any]]:
    """Size of a batch of n readings in our layout: (CBOR bytes, JSON bytes, the metadata object)."""
    obj = layout.build_batch("GW01", 12345, make_readings(n, sensors))
    layout.check_metadata(obj)
    return layout.cbor_len(obj[str(layout.LABEL)]), len(layout.dump(obj)), obj


def old_size(n: int) -> int:
    """CBOR bytes of n readings in the older sample layout."""
    return layout.cbor_len([old_style(r) for r in make_readings(n)])


def max_fit(size_fn: Callable[[int], int], limit: int) -> int:
    """Largest n (by bisection) for which size_fn(n) <= limit."""
    lo, hi = 1, MAX_SEARCH
    while lo < hi:
        mid = (lo + hi + 1) // 2
        lo, hi = (mid, hi) if size_fn(mid) <= limit else (lo, mid - 1)
    return lo


def longest_string(obj: Any) -> int:
    """Length in bytes of the longest text string anywhere inside the metadata object."""
    longest = 0

    def walk(x):
        nonlocal longest
        if isinstance(x, str):
            longest = max(longest, len(x.encode()))
        elif isinstance(x, (list, dict)):
            for i in (x.items() if isinstance(x, dict) else x):
                for j in (i if isinstance(i, tuple) else (i,)):
                    walk(j)
    walk(obj)
    return longest


def main() -> None:
    """Print the size table, the maximum batch sizes and the string-length check."""
    reserve = layout.TX_RESERVE
    wrap = layout.AUX_WRAP + 3
    room = layout.MAX_TX - reserve - wrap
    print("Limit: %d bytes per transaction. Default reserve %d bytes for everything except the metadata"
          " (plain payment ~%d, contract transaction ~%d)," % (layout.MAX_TX, reserve, layout.PLAIN_OVERHEAD,
                                                              layout.CONTRACT_OVERHEAD))
    print("so %d bytes for the metadata value." % room)
    print("Test data: %d sensors per batch (ids like AGRI_001), sequence numbers near %d, 20 s of readings per batch.\n"
          % (SENSORS, SEQ_START))

    print("%6s | %9s %9s %9s | %8s %9s | %10s"
          % ("B", "CBOR", "JSON", "B/reading", "plain tx", "contract", "old-style"))
    for n in BATCH_SIZES:
        cbor, json_bytes, _ = new_size(n)
        print("%6d | %9d %9d %9.1f | %8d %9d | %10d" % (
            n, cbor, json_bytes, cbor / n, cbor + wrap + layout.PLAIN_OVERHEAD,
            cbor + wrap + layout.CONTRACT_OVERHEAD, old_size(n)))
    print()

    for res in (layout.PLAIN_OVERHEAD, reserve):
        limit = layout.MAX_TX - res - wrap
        print("reserve %4d: max readings per transaction, 10 sensors: %4d   50 sensors: %4d   200 sensors: %4d"
              "   old-style: %d" % (res, max_fit(lambda n: new_size(n, 10)[0], limit),
                                    max_fit(lambda n: new_size(n, 50)[0], limit),
                                    max_fit(lambda n: new_size(n, 200)[0], limit), max_fit(old_size, limit)))

    _, _, obj = new_size(1000)
    print("\nlongest text string in the new layout: %d bytes (limit %d) -> the 64-byte limit never binds "
          "(ids are at most 32);" % (longest_string(obj), layout.MAX_STR))
    print("it would only matter for a layout that packs many readings into one long string.")


if __name__ == "__main__":
    main()
