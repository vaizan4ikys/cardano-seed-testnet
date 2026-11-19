#!/bin/bash
# Fork statistics: how many of the blocks the pools forged did NOT end up in the chain, and why.
# Runs on the machine that hosts the chain. It only reads: the node log of each pool container
# (/var/log/cardano-node.log) and the chain tip. It never writes to the chain and prints no keys.
#
#   ./scripts/fork-stats.sh                            everything since the chain started
#   ./scripts/fork-stats.sh --since "2026-11-19 22:00"  only blocks forged from that time on (log time = UTC)
#   ./scripts/fork-stats.sh --list                     also list every block that is not in the chain
#   NET=2 ./scripts/fork-stats.sh                      network 2
#
# Why blocks get lost: two pools win the same slot (or a second pool forges before it has seen the first
# block), both forge, and each node keeps the block it saw first or the one that wins the VRF tie-break.
# The loser is dropped ("Switched to a fork"). It is normal Cardano behaviour, not a bug.
#
# What it reads (one line each in the node log):
#   Forge.Loop.ForgedBlock                 "Forged block in slot N"                  a pool forged a block
#   Forge.Loop.AdoptedBlock                "Adopted block forged in slot N: <hash>"  ... and put it on its own chain
#   Forge.Loop.DidntAdoptBlock             "Didn't adopt forged block in slot N"     ... but could not
#   ChainDB.AddBlockEvent.AddedToCurrentChain  "new tip: <hash> at slot N"           the node's chain got one block longer
#   ChainDB.AddBlockEvent.SwitchedToAFork      "new tip: <hash> at slot N"           the node dropped its newest block(s)
set -eo pipefail
source "$(dirname "$0")/lib.sh"

# ---- arguments ----
SINCE=""; LIST=0
while [ $# -gt 0 ]; do
  case $1 in
    --since) SINCE=${2:?"--since needs a time, e.g. \"2026-11-19 22:00\""}; shift 2 ;;
    --list)  LIST=1; shift ;;
    -h|--help) sed -n '2,9p' "$0" | cut -c3-; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 1 ;;
  esac
done

# ---- read the logs: only the few event types we need, one file per pool ----
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
EVENTS='Forge.Loop.(ForgedBlock|AdoptedBlock|DidntAdoptBlock)\]|AddBlockEvent.(AddedToCurrentChain|SwitchedToAFork)\]'
for n in 1 2 3; do
  # "|| true": grep exits 1 when a log has no such line yet (a very young chain); that is not an error here
  docker exec "$(require_pool "$n")" grep -E "$EVENTS" /var/log/cardano-node.log > "$TMP/pool$n.log" || true
done
# block number of the tip (the first block is number 0), to check that the log is complete
TIP_BLOCK=$(docker exec "$(require_pool 1)" cardano-cli conway query tip --testnet-magic "$MAGIC" \
  --socket-path "$SOCKET" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['block'])" || true)

python3 - "$TMP" "$SINCE" "$LIST" "${TIP_BLOCK:-}" <<'PY'
import re, sys
from collections import Counter

tmp, since, list_all, tip_block = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4]
LINE = re.compile(r"\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\.\d+Z\]\[[^:\]]*:([A-Za-z.]+)\]\([A-Za-z]+,\d+\) (.*)")
TIP = re.compile(r"new tip: (\w+) at slot (\d+)")
SLOT_HASH = re.compile(r"slot (\d+): (\w+)")
SLOT = re.compile(r"slot (\d+)")
POOLS = (1, 2, 3)
if since and len(since) == 16:
    since += ":00"                      # "2026-11-19 22:00" -> "2026-11-19 22:00:00"

forged = []           # (time, pool, slot) for every block a pool forged
adopted = {}          # (pool, slot) -> hash of the block the pool put on its own chain
not_adopted = set()   # (pool, slot) the pool could not put on its own chain
chain = {}            # hash -> slot, the blocks of the chain as pool 1 sees it at the end of the log
chain_by_slot = {}    # slot -> hash
switches = Counter()  # pool -> fork switches since --since
deepest = {}          # pool -> (blocks dropped, time) of the deepest rollback
first_t = last_t = None

for n in POOLS:
    stack = []        # the node's chain as a list of (slot, hash), rebuilt from its own log lines
    for line in open("%s/pool%d.log" % (tmp, n), errors="replace"):
        m = LINE.match(line)
        if not m:
            continue
        t, kind, rest = m.groups()
        first_t = t if first_t is None or t < first_t else first_t
        last_t = t if last_t is None or t > last_t else last_t
        if kind.endswith("ForgedBlock"):
            forged.append((t, n, int(SLOT.search(rest).group(1))))
        elif kind.endswith("AdoptedBlock"):
            s, h = SLOT_HASH.search(rest).groups()
            adopted[(n, int(s))] = h
        elif kind.endswith("DidntAdoptBlock"):
            not_adopted.add((n, int(SLOT.search(rest).group(1))))
        elif kind.endswith("AddedToCurrentChain") or kind.endswith("SwitchedToAFork"):
            h, s = TIP.search(rest).groups()
            s = int(s)
            if kind.endswith("SwitchedToAFork"):
                # How deep was the rollback? A block can only be an ancestor of the new tip if its slot is
                # lower, so every block at the top of our list with slot >= the new tip's slot was dropped.
                # Limit: if the new tip has a HIGHER slot than the old one but sits on a different branch
                # (dropped 1 block, added 2), the log shows only the new tip and the drop is not seen.
                # So this is a lower bound; the check against the tip block number below shows if it matters.
                dropped = 0
                while stack and stack[-1][0] >= s:
                    stack.pop(); dropped += 1
                if not since or t >= since:
                    switches[n] += 1
                    if dropped > deepest.get(n, (0, ""))[0]:
                        deepest[n] = (dropped, t)
            stack.append((s, h))
    if n == 1:
        chain = {h: s for s, h in stack}
        chain_by_slot = {s: h for s, h in stack}
        chain_len = len(stack)

if first_t is None:
    sys.exit("no blocks found in the logs (is the chain running?)")

def seconds(a, b):
    from datetime import datetime
    f = "%Y-%m-%d %H:%M:%S"
    return int((datetime.strptime(b, f) - datetime.strptime(a, f)).total_seconds())

win = [f for f in forged if not since or f[0] >= since]
start = since or first_t
if not win:
    sys.exit("no block was forged since %s (log covers %s to %s UTC)" % (since, first_t, last_t))

def reason(pool, slot):
    h = adopted.get((pool, slot))
    if h in chain:
        return None
    if slot in chain_by_slot:
        return "lost a same-slot tie"
    if (pool, slot) in not_adopted:
        return "not adopted by its own pool"
    return "dropped by a fork switch, no same-slot block"

per_pool = Counter(); lost_pool = Counter(); reasons = Counter(); lost = []
for t, n, s in win:
    per_pool[n] += 1
    why = reason(n, s)
    if why:
        lost_pool[n] += 1; reasons[why] += 1; lost.append((t, n, s, why))
total, nlost = len(win), len(lost)
in_chain = total - nlost
span = seconds(start, last_t)
slots_with = Counter(s for _, _, s in win)
double = sum(1 for c in slots_with.values() if c > 1)

print("Fork statistics (from the pool logs, times are UTC)")
print("  period:                  %s to %s  (%d min)" % (start, last_t, span // 60))
print("  blocks in the chain:     %d  (one every %.1f s; expected about 5 s = 1 / activeSlotsCoeff 0.2)"
      % (in_chain, span / max(in_chain, 1)))
print("  blocks forged:           %d  (%s)" % (total, ", ".join("pool %d: %d" % (n, per_pool[n]) for n in POOLS)))
print("  forged, not in chain:    %d = %.1f %% of the forged blocks  (%s)"
      % (nlost, 100.0 * nlost / total, ", ".join("pool %d: %d" % (n, lost_pool[n]) for n in POOLS)))
for why in ("lost a same-slot tie", "not adopted by its own pool", "dropped by a fork switch, no same-slot block"):
    if reasons[why]:
        print("    %-45s %d" % (why + ":", reasons[why]))
print("  slots with 2 blocks:     %d  (two pools won the same slot; one of the two is always lost)" % double)
print("  fork switches:           %s" % ", ".join("pool %d: %d" % (n, switches[n]) for n in POOLS))
if deepest:
    d, t = max(deepest.values())
    print("  deepest rollback:        %d block%s (at %s); lower bound, see the comments in this script"
          % (d, "" if d == 1 else "s", t))
else:
    print("  deepest rollback:        none in this period")

# check: the chain rebuilt from pool 1's log must have as many blocks as the tip says (block numbers start at 0)
if tip_block.isdigit():
    if int(tip_block) + 1 == chain_len:
        print("  check:                   OK, pool 1's rebuilt chain has %d blocks = tip block number %s + 1" % (chain_len, tip_block))
    else:
        print("  check:                   WARNING, rebuilt chain has %d blocks but the tip is block number %s; "
              "numbers above are approximate (the log may be incomplete or a deep fork was not seen)" % (chain_len, tip_block))
else:
    print("  check:                   tip not readable, chain length not verified")

if list_all and lost:
    print("\nBlocks forged but not in the chain:")
    for t, n, s, why in lost:
        print("  %s  pool %d  slot %d  %s" % (t, n, s, why))
PY
