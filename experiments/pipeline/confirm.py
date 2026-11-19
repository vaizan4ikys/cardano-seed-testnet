"""ChainView: what the gateway wants to know about a transaction it sent: is it in a block, and how deep?

Why: a block can be replaced by a competing block of another pool. The transactions of the replaced block are NOT put
back into the mempool, so a batch that was "in a block once" can vanish. The gateway therefore keeps asking, until the
transaction is final (k blocks on top, k = 60 on this chain).

How (the same method as the web page, see reader.py):
  * Kupo says where a transaction is: its slot and the header hash of its block (/matches/*@txid).
  * The node says how long the chain is: the tip block number (reader.DockerTip, `docker exec cardano-cli`).
  * Kupo has no block numbers. The block of a transaction is the tip block at the moment it was first seen
    (reader.first_seen_block); depth = tip block - block + 1. When it is first seen late, the tip block
    is used (it is never older than the real block), so "final" may come late, never early.

Kupo is started without --prune-utxo, so a spent output stays listed. If a Kupo did prune, a transaction whose outputs
are all spent would look missing; as a safety net we then ask for its metadata in the slot where we saw it before
(/metadata/<slot>), which Kupo keeps, and log a warning.

Reads from the network only, writes nothing. Used by gateway.py.
"""
from __future__ import annotations

import time
from typing import Any, Callable, Dict, Optional, Tuple

import reader

MAX_KUPO_LAG_SLOTS = 30       # a Kupo more slots behind the node than this is not trusted to say "missing"
TIP_FRESH_S = 10              # a tip older than this is not used as the first-seen block (reader.TIP_STALE_S)


class ChainView:
    """Questions about the chain, answered through Kupo (kupo = reader.KupoClient) and the node tip.

    Call refresh() first in every round (it asks Kupo's health and the node tip once); then locate(), new_block()
    and depth() work with that tip."""

    def __init__(self, kupo: Any, tip_source: Any, log: Callable[[str], None] = reader.default_log,
                 clock: Callable[[], float] = time.monotonic):
        self.kupo, self.tip_source, self.log, self.clock = kupo, tip_source, log, clock
        self.tip: Optional[Dict[str, Any]] = None     # {'block', 'slot', 'hash'} of the last good tip query
        self.tip_time = 0.0
        self.warned_pruning = False

    def refresh(self) -> Optional[str]:
        """Ask Kupo for its health and the node for its tip. Returns None when the answers can be trusted,
        else a short text why not (Kupo down, not connected to the node, far behind, no tip)."""
        try:
            health = self.kupo.health()
        except Exception as e:
            return "Kupo does not answer (%s)" % e
        if not health["connected"]:
            return "Kupo is not connected to the node"
        behind = health["node_tip"] - health["checkpoint"]
        if behind > MAX_KUPO_LAG_SLOTS:
            return "Kupo is %d slots behind the node" % behind
        try:
            self.tip = self.tip_source.get()
        except Exception as e:
            return "no node tip (%s)" % e
        self.tip_time = self.clock()
        return None

    def locate(self, txid: str, slot_hint: Optional[int] = None) -> Optional[Tuple[int, Optional[str]]]:
        """(slot, header hash) of the block that holds the transaction now, or None when Kupo does not have it.
        slot_hint = the slot where we saw it before (only used in the safety net for a pruning Kupo).
        Raises when Kupo cannot be reached: the caller must not take that for "missing"."""
        found = self.kupo.find_transaction(txid)
        if found is not None or slot_hint is None:
            return found
        obj, _, header = self.kupo.batch(slot_hint, txid)       # metadata is kept even when spent outputs are pruned
        if obj is None:
            return None
        if not self.warned_pruning:
            self.warned_pruning = True
            self.log("WARNING Kupo has the metadata of transaction %s... but lists none of its outputs: it seems "
                     "to prune spent outputs (--prune-utxo); start it as kupo.sh does" % txid[:12])
        return slot_hint, header

    def new_block(self, slot: int) -> Optional[int]:
        """Block number to remember for a transaction that is found in `slot` for the first time.

        Final must never come too early, only late. So an estimate is never stored as if it were exact:
          * found close to a fresh tip: the exact block (the tip block, or the next one);
          * found far behind a fresh tip (a restart, a long Kupo pause): the exact block is not known, but it is
            never newer than the tip block, so the tip block is stored. Depth is then counted from there and can
            only be too small (final late), never too large;
          * the tip is older than TIP_FRESH_S: None. The batch is looked at again in the next round."""
        if not self.tip or self.clock() - self.tip_time > TIP_FRESH_S:
            return None
        block, estimate = reader.first_seen_block(self.tip, True, slot)
        return self.tip["block"] if estimate else block

    def depth(self, block: Optional[int]) -> Optional[int]:
        """Blocks on top of a transaction in `block` (1 = in the tip block); None when not known."""
        if block is None or self.tip is None:
            return None
        return max(self.tip["block"] - block + 1, 1)
