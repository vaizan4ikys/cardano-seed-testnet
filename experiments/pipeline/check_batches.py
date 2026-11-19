#!/usr/bin/env python3
"""Did every batch of a gateway reach the chain and become final? Reads the outbox and Kupo, changes nothing.

  python3 check_batches.py --outbox /tmp/demo-run-1/outboxA --kupo http://10.150.0.71:1442
  python3 check_batches.py --outbox outbox --kupo http://10.150.0.71:1442 --gateway-id GW01 --list

Every batch file of the outbox ends in exactly one group:
  final     in the chain, at least --final-blocks blocks on top (cannot be replaced any more)
  settling  in the chain, fewer blocks on top: a replaced block could still take it away
  pending   written, but never sent (the gateway is still working on it, or it is stopped)
  dead      in dead/: refused for good (for example the gateway is not approved) or failed too often
            (some may have been sent before); not in the chain
  LOST      the gateway says "sent", but the batch is NOT in the chain: the readings are gone

How a batch is found on the chain (the first that works):
  1. by its transaction id, when the gateway stored one (batch-....json.tx, written by the new gateway.py)
  2. by its hash: the batch hash is in the file name and is also the hash of the batch on the chain
  3. by content: every reading (gateway id, sensor id, sequence number) of the file is in some batch on the chain.
     This is what makes the check work on an outbox written by the OLD gateway, which stored no transaction id.
How deep it is: a batch the new gateway has seen in a block has its block number in the .tx file; otherwise the page's
estimate is used (reader.estimated_block: tip block and slots). The tip comes from docker exec (reader.DockerTip); where
docker is not available, from Kupo's slot (about 0.2 blocks per slot): then "settling/final" is only approximate.

Exit code: 0 = nothing LOST, 1 = something LOST, 2 = Kupo cannot be read. Standard library only.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from typing import Any, Dict, List, Optional, Tuple

import layout
import reader

FINAL, SETTLING, PENDING, DEAD, LOST = "final", "settling", "pending", "dead", "LOST"
GROUPS = (FINAL, SETTLING, PENDING, DEAD, LOST)
SENT_WORDS = ("sent", "settling", "final")       # status words of a batch the gateway has submitted


def read_outbox(outbox: str, gateway_id: Optional[str] = None) -> List[Dict[str, Any]]:
    """One entry per batch file of the outbox and of outbox/dead (oldest first): name, status word, dead flag,
    the .tx content (or None), the file's gateway id and its readings as a set of (gateway, sensor, seq).
    A file that cannot be read or is not our layout is skipped with a warning on stderr."""
    entries = []
    for folder, dead in ((outbox, False), (os.path.join(outbox, "dead"), True)):
        for path in sorted(glob.glob(os.path.join(folder, "batch-*.json"))):
            name = os.path.basename(path)
            try:
                with open(path, "rb") as f:
                    data = f.read()
                parsed = reader.parse_our_batch(json.loads(data))
            except (OSError, ValueError, KeyError, TypeError) as e:
                print("skipped %s: %s" % (name, e), file=sys.stderr)
                continue
            if gateway_id and parsed["gateway"] != gateway_id:
                continue
            entries.append({"name": name, "dead": dead, "status": (read_words(path + ".status") or ["pending"])[0],
                            "tx": read_json(path + ".tx"), "hash": layout.batch_hash(data),
                            "gateway": parsed["gateway"],
                            "readings": {(parsed["gateway"], r["sensor"], r["seq"]) for r in parsed["readings"]}})
    return sorted(entries, key=lambda e: e["name"])


def read_words(path: str) -> List[str]:
    """The words of a small text file ([] if it is missing)."""
    try:
        with open(path) as f:
            return f.read().split()
    except OSError:
        return []


def read_json(path: str) -> Optional[Dict[str, Any]]:
    """A small JSON file (None if it is missing or damaged)."""
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


class Chain:
    """The batches on the chain, read from Kupo only when they are needed (the whole chain is read once).

    kupo needs find_transaction(txid), new_transactions(slot) and batch(slot, txid) (kupo_reader.Kupo)."""

    def __init__(self, kupo: Any):
        self.kupo = kupo
        self._by_hash = None            # batch hash -> (slot, txid)
        self._by_reading = None         # (gateway, sensor, seq) -> highest slot of a batch that holds it

    def by_txid(self, txid: str) -> Optional[int]:
        """Slot of the transaction, or None if Kupo does not list it."""
        found = self.kupo.find_transaction(txid)
        return found[0] if found else None

    def _read_all(self) -> None:
        """Read every transaction of the chain that carries one of our batches."""
        self._by_hash, self._by_reading = {}, {}
        for slot, txid in self.kupo.new_transactions(0):
            obj, h, _ = self.kupo.batch(slot, txid)
            if obj is None:
                continue
            try:
                parsed = reader.parse_our_batch(obj)
            except (ValueError, KeyError, TypeError):
                continue                                    # a label-1000 transaction of another layout
            self._by_hash[h] = (slot, txid)
            for r in parsed["readings"]:
                key = (parsed["gateway"], r["sensor"], r["seq"])
                self._by_reading[key] = max(slot, self._by_reading.get(key, 0))

    def by_hash(self, h: str) -> Optional[int]:
        """Slot of the batch with this hash, or None."""
        if self._by_hash is None:
            self._read_all()
        found = self._by_hash.get(h)
        return found[0] if found else None

    def by_content(self, readings: set) -> Optional[int]:
        """Highest slot of the batches that hold the readings, if EVERY reading is on the chain; else None."""
        if self._by_reading is None:
            self._read_all()
        slots = [self._by_reading.get(key) for key in readings]
        return None if not readings or None in slots else max(slots)


def find_on_chain(entry: Dict[str, Any], chain: Chain) -> Tuple[Optional[int], str]:
    """(slot, how it was found) of a batch on the chain; (None, "") if it is not there."""
    tx = entry["tx"]
    if tx and tx.get("txid"):
        slot = chain.by_txid(tx["txid"])
        if slot is not None:
            return slot, "transaction id"
    slot = chain.by_hash(entry["hash"])
    if slot is not None:
        return slot, "hash"
    slot = chain.by_content(entry["readings"])
    if slot is not None:
        return slot, "content"
    return None, ""


def depth_of(entry: Dict[str, Any], slot: int, tip: Optional[Dict[str, Any]]) -> Optional[int]:
    """Blocks on top of a batch in `slot`. The gateway's own record of the block (if it is for the same slot) is
    better than the estimate. None when there is no tip."""
    if tip is None:
        return None
    tx = entry["tx"]
    if tx and tx.get("block") is not None and tx.get("slot") == slot:
        block = tx["block"]
    else:
        block = reader.estimated_block(tip, slot)
    return max(tip["block"] - block + 1, 1)


def classify(entries: List[Dict[str, Any]], chain: Chain, final_blocks: int,
             tip: Optional[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Add "group" (one of GROUPS), "slot", "found" (how) and "depth" to every entry."""
    for e in entries:
        e.update({"slot": None, "found": "", "depth": None})
        if e["dead"]:
            e["group"] = DEAD
        elif e["status"] not in SENT_WORDS:
            e["group"] = PENDING
        else:
            e["slot"], e["found"] = find_on_chain(e, chain)
            if e["slot"] is None:
                e["group"] = LOST
            else:
                e["depth"] = depth_of(e, e["slot"], tip)
                e["group"] = FINAL if e["status"] == "final" or (e["depth"] or 0) >= final_blocks else SETTLING
    return entries


def slot_tip(kupo: Any) -> Optional[Dict[str, Any]]:
    """A tip made from Kupo's slot alone (no docker): block number = slot * blocks per slot. Approximate."""
    health = kupo.health()
    slot = health["checkpoint"]
    return {"block": int(slot * reader.FALLBACK_BLOCKS_PER_SLOT), "slot": slot, "hash": None}


def report(entries: List[Dict[str, Any]], final_blocks: int, show_list: bool) -> str:
    """The text printed at the end: counts per group (batches and readings) and, for LOST, the file names."""
    count = {g: [e for e in entries if e["group"] == g] for g in GROUPS}
    explain = {FINAL: "in the chain, %d or more blocks on top" % final_blocks,
               SETTLING: "in the chain, fewer blocks on top: could still be replaced",
               PENDING: "written, never sent",
               DEAD: "refused or failed too often (some may have been sent before); not in the chain",
               LOST: "the gateway says sent, but NOT in the chain"}
    lines = ["batches in the outbox: %d" % len(entries)]
    for g in GROUPS:
        readings = sum(len(e["readings"]) for e in count[g])
        lines.append("  %-9s %5d batches  %7d readings   %s" % (g, len(count[g]), readings, explain[g]))
    by_content = [e for e in entries if e["found"] == "content"]
    if by_content:
        lines.append("  (%d batches were found by their readings, not by hash or transaction id)" % len(by_content))
    if count[LOST]:
        lines.append("LOST: %d batches, %d readings are not in the chain:"
                     % (len(count[LOST]), sum(len(e["readings"]) for e in count[LOST])))
        for e in count[LOST][: None if show_list else 10]:
            lines.append("  " + e["name"])
        if len(count[LOST]) > 10 and not show_list:
            lines.append("  ... (--list shows all)")
    else:
        lines.append("OK: no batch is lost")
    return "\n".join(lines)


def main() -> int:
    """Read the options, read outbox and chain, print the report. Returns the exit code."""
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--outbox", required=True, help="outbox folder of the gateway (batch files, dead/)")
    ap.add_argument("--kupo", required=True, help="URL of Kupo, e.g. http://10.150.0.71:1442")
    ap.add_argument("--gateway-id", default=None, help="only the batches of this gateway (default: all in the folder)")
    ap.add_argument("--final-blocks", type=int, default=60, help="blocks on top until a batch is final (k)")
    ap.add_argument("--container", default=None, help="pool 1 container name for the node tip (default: docker ps)")
    ap.add_argument("--magic", type=int, default=reader.DEFAULT_MAGIC, help="network magic of the chain")
    ap.add_argument("--list", action="store_true", help="list all LOST batches (default: the first 10)")
    a = ap.parse_args()
    if not os.path.isdir(a.outbox):
        print("no such folder: %s" % a.outbox, file=sys.stderr)
        return 2

    kupo = reader.KupoClient(a.kupo)
    entries = read_outbox(a.outbox, a.gateway_id)
    try:
        kupo.health()
        try:
            tip = reader.DockerTip(a.container, a.magic).get()
            tip_text = "tip block %d (node)" % tip["block"]
        except Exception as e:
            tip = slot_tip(kupo)
            tip_text = "tip block about %d (from Kupo's slot, no docker: %s)" % (tip["block"], str(e)[:60])
        entries = classify(entries, Chain(kupo), a.final_blocks, tip)
    except Exception as e:
        print("cannot read the chain through Kupo at %s: %s" % (a.kupo, e), file=sys.stderr)
        return 2
    print("outbox %s, gateway %s, Kupo %s, %s" % (a.outbox, a.gateway_id or "(any)", a.kupo, tip_text))
    print(report(entries, a.final_blocks, a.list))
    return 1 if any(e["group"] == LOST for e in entries) else 0


if __name__ == "__main__":
    sys.exit(main())
