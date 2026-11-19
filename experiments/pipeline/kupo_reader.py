"""Read batches back from the chain through Kupo (HTTP, standard library only).

Kupo follows the chain and keeps what it sees; we ask it two things:
  /matches?created_after=<slot>&order=oldest_first   which transactions are new (slot and transaction id)
  /metadata/<slot>?transaction_id=<id>                the metadata of one transaction
  /matches/*@<id>                                     where one transaction is (its outputs, spent ones too)

Kupo shows metadata as typed JSON ({"int": 5}, {"string": "x"}, {"list": [...]}, {"map": [...]}).
schema_to_plain turns it back into plain JSON, and batch_from_metadata rebuilds the exact bytes of the
batch file, so the page can check the batch hash (sha256 of those bytes).

Recent blocks can still change (a rollback). Kupo sends the header hash of the block with every metadata
answer (the X-Block-Header-Hash header); keep it, and show a batch as final only when it is k blocks deep.

Kupo is started WITHOUT --prune-utxo (kupo.sh), so an output that is spent stays listed. The gateway (confirm.py)
and check_batches.py rely on that to find a transaction whose change output has been spent already.

Used by reader.py (KupoClient adds /health and the raw match list). Reads from the network only, writes nothing.
"""
from __future__ import annotations

import json
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

import layout

DEFAULT_URL = "http://127.0.0.1:1442"   # Kupo on the same machine (the lab uses the container IP, see kupo.sh)
TIMEOUT_S = 20                           # seconds for one HTTP request


def schema_to_plain(s: Dict[str, Any]) -> Any:
    """Kupo's typed metadata JSON -> plain JSON (bytes become "0x<hex>" strings)."""
    if "int" in s:
        return s["int"]
    if "string" in s:
        return s["string"]
    if "bytes" in s:
        return "0x" + s["bytes"]
    if "list" in s:
        return [schema_to_plain(x) for x in s["list"]]
    if "map" in s:
        return {str(schema_to_plain(e["k"])): schema_to_plain(e["v"]) for e in s["map"]}
    raise ValueError("unknown metadata type: %r" % (s,))


def batch_from_metadata(item: Dict[str, Any]) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
    """One item of Kupo's /metadata answer -> (metadata object, batch hash) for our label.
    Returns (None, None) if the transaction has no metadata under our label."""
    schema = item.get("schema", {})
    if str(layout.LABEL) not in schema:
        return None, None
    obj = {str(layout.LABEL): schema_to_plain(schema[str(layout.LABEL)])}
    return obj, layout.batch_hash(layout.dump(obj))


class Kupo:
    """Small HTTP client for the two Kupo questions we need."""

    def __init__(self, base: str = DEFAULT_URL, timeout: int = TIMEOUT_S):
        self.base, self.timeout = base, timeout

    def _get(self, path: str, **params: Any) -> Tuple[Any, Dict[str, str]]:
        """GET base+path (?params); returns (decoded JSON, response headers). Raises on network/HTTP errors."""
        url = self.base + path + ("?" + urllib.parse.urlencode(params) if params else "")
        with urllib.request.urlopen(url, timeout=self.timeout) as r:
            return json.loads(r.read().decode()), dict(r.headers)

    def new_transactions(self, after_slot: int) -> List[Tuple[int, str]]:
        """[(slot, transaction_id)] of transactions created at or after a slot, oldest first, no repeats."""
        matches, _ = self._get("/matches", created_after=max(after_slot, 1), order="oldest_first")
        seen, out = set(), []
        for m in matches:
            key = (m["created_at"]["slot_no"], m["transaction_id"])
            if key not in seen:
                seen.add(key)
                out.append(key)
        return out

    def batch(self, slot: int, txid: str) -> Tuple[Optional[Dict[str, Any]], Optional[str], Optional[str]]:
        """(metadata object, batch hash, block header hash) of one transaction, or (None, None, None)."""
        items, headers = self._get("/metadata/%d" % slot, transaction_id=txid)
        header = headers.get("X-Block-Header-Hash")
        for item in items:
            obj, h = batch_from_metadata(item)
            if obj is not None:
                return obj, h, header
        return None, None, header

    def find_transaction(self, txid: str) -> Optional[Tuple[int, Optional[str]]]:
        """(slot, block header hash) of the block that holds this transaction, or None if Kupo does not list it.
        Asks for every output of the transaction (/matches/*@txid); spent outputs are listed too."""
        matches, _ = self._get("/matches/*@" + txid)
        if not matches:
            return None
        at = matches[0]["created_at"]
        return at["slot_no"], at.get("header_hash")
