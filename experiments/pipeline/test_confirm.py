"""Tests for following batches until they are final (confirm.py, gateway.py) and for check_batches.py.
No chain and no network: Kupo, the node tip and the submit step are simulated.
Run:  python3 -m unittest -v test_confirm  (in this folder)"""
import json
import os
import shutil
import tempfile
import threading
import unittest

import check_batches
import confirm
import gateway
import kupo_reader
import layout

K = 60                   # blocks until final in these tests


def reading(seq, sensor="AGRI_001"):
    return {"sensor_id": sensor, "seq": seq, "ts": 1760000000 + seq, "kind": "temperature", "value": 2450, "scale": 100}


def txid_of(n):
    """A fake transaction id: 64 hex characters."""
    return "%064x" % n


def quiet(msg):
    pass


class FakeClock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


class FakeChain:
    """Kupo and the node tip in one: a transaction is "in a block" after add(), gone after drop().
    Every block is 5 slots; the tip block and slot grow with advance()."""

    def __init__(self):
        self.txs = {}                    # txid -> (slot, header hash)
        self.block, self.slot = 1000, 5000
        self.down = False
        self.metadata = {}               # (slot, txid) -> batch object: what /metadata answers even if no outputs
        self.listed = []                 # [(slot, txid, obj)] for check_batches: the batches on the chain

    def add(self, txid, header="aa"):
        self.txs[txid] = (self.slot, header)

    def drop(self, txid):
        self.txs.pop(txid, None)

    def advance(self, blocks):
        self.block += blocks
        self.slot += 5 * blocks

    # what the ChainView / Kupo client is asked
    def health(self):
        if self.down:
            raise OSError("connection refused")
        return {"checkpoint": self.slot, "node_tip": self.slot, "connected": True, "synced": 1.0}

    def find_transaction(self, txid):
        if self.down:
            raise OSError("connection refused")
        return self.txs.get(txid)

    def batch(self, slot, txid):
        obj = self.metadata.get((slot, txid))
        return (obj, layout.batch_hash(layout.dump(obj)) if obj else None, "aa")

    def new_transactions(self, after_slot):
        return [(slot, txid) for slot, txid, _ in self.listed]

    def get(self):                       # the node tip
        return {"block": self.block, "slot": self.slot, "hash": "tip"}


class Submitter:
    """A fake submit step: returns a new transaction id per call, or what `answer` says."""

    def __init__(self):
        self.calls = []                  # (file name, hash)
        self.txids = []                  # the id given for each call
        self.answer = None               # None = a new transaction id; else True / False / "refused"

    def __call__(self, path, h):
        self.calls.append((os.path.basename(path), h))
        if self.answer is not None:
            return self.answer
        self.txids.append(txid_of(len(self.calls)))
        return self.txids[-1]


class FollowCase(unittest.TestCase):
    """A gateway with a fake chain, a fake submit step and a fake clock, in a temporary outbox."""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="confirm-test-")
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.chain, self.sub, self.clock, self.logs = FakeChain(), Submitter(), FakeClock(), []
        self.gw = self.make()

    def make(self, with_view=True, max_tries=5):
        view = confirm.ChainView(self.chain, self.chain, quiet, self.clock) if with_view else None
        return gateway.Gateway(self.dir, 1, 10, self.sub, clock=self.clock, log=self.logs.append, view=view,
                               final_blocks=K, missing_grace=60, max_tries=max_tries)

    def send_batches(self, n, gw=None):
        """Write n batches (one reading each) and submit them. Returns the file names, oldest first."""
        gw = gw or self.gw
        first = len(self.sub.calls) + 1
        for seq in range(first, first + n):
            gw.add_reading(reading(seq))
        gw.send_pending()
        return sorted(f for f in os.listdir(self.dir) if f.startswith("batch-") and f.endswith(".json"))

    def status(self, name):
        with open(os.path.join(self.dir, name + ".status")) as f:
            return f.read()

    def tx(self, name):
        with open(os.path.join(self.dir, name + ".tx")) as f:
            return json.load(f)


class TestFindTxid(unittest.TestCase):
    H = "ab" * 32

    def test_the_two_lines_p1_batch_prints(self):
        ok = "OK: gateway A batch %s is in a block: tx %s (size 1500 bytes, fee 400000 lovelace, 5100 ms)"
        old = "already sent: batch %s is transaction %s"
        for line in (ok, old):
            out = "some noise\n" + line % (self.H, txid_of(7)) + "\n"
            self.assertEqual(gateway.find_txid(out, self.H), txid_of(7))

    def test_no_txid(self):
        self.assertIsNone(gateway.find_txid("", self.H))
        self.assertIsNone(gateway.find_txid("submitted but not seen in a block yet", self.H))
        self.assertIsNone(gateway.find_txid("batch %s" % self.H, self.H))      # only the batch hash is not a txid
        self.assertIsNone(gateway.find_txid("tx %s\nlast line without it" % txid_of(1), self.H))

    def test_command_returns_the_txid(self):
        script = "echo noise; echo 'OK: batch %s is in a block: tx %s (size 1)'" % (self.H, txid_of(9))
        sub = gateway.make_submit("command", "sh -c \"%s\" x" % script, log=quiet)
        self.assertEqual(sub("file.json", self.H), txid_of(9))
        sub0 = gateway.make_submit("command", "sh -c 'echo fine' x", log=quiet)
        self.assertIs(sub0("file.json", self.H), True)         # success without a transaction id


    def test_notes_on_stderr_are_not_the_answer(self):
        """p1-batch.sh prints its resend / repair notes on stderr, after the OK line."""
        ok = "OK: gateway A batch %s is in a block: tx %s (size 1500 bytes)" % (self.H, txid_of(5))
        notes = ["  not in a block after 10 s: sent the same transaction again",
                 "note: registry.ref pointed to a coin that is gone (%s#0); now using %s#0 (found by its token)"
                 % (txid_of(70), txid_of(71))]
        for note in notes:
            script = "echo '%s'; echo '%s' >&2" % (ok, note)
            sub = gateway.make_submit("command", "sh -c \"%s\" x" % script, log=quiet)
            self.assertEqual(sub("file.json", self.H), txid_of(5), note)
        # nothing on stdout but a note on stderr: no txid (the batch is "sent", not followed)
        sub = gateway.make_submit("command", "sh -c \"echo '%s' >&2\" x" % notes[1], log=quiet)
        self.assertIs(sub("file.json", self.H), True)

    def test_a_refusal_shows_the_reason_not_the_note(self):
        """Seen on the VM: the REFUSED line showed the stderr note "registry.ref pointed to ..." instead of the reason."""
        logs = []
        script = ("echo 'note: registry.ref pointed to a coin that is gone' >&2; "
                  "echo 'REFUSED by the contract: gateway A is not on the registry list'; exit 2")
        sub = gateway.make_submit("command", "sh -c \"%s\" x" % script, log=logs.append)
        self.assertEqual(sub("/x/b.json", self.H), "refused")
        self.assertEqual(logs, ["REFUSED, not retried: REFUSED by the contract: gateway A is not on the registry list"])
        logs.clear()
        script = "echo 'a note' >&2; echo 'submit failed: BadInputsUTxO'; exit 1"
        sub = gateway.make_submit("command", "sh -c \"%s\" x" % script, log=logs.append)
        self.assertIs(sub("/x/b.json", self.H), False)
        self.assertEqual(logs, ["submit command exit 1: a note\nsubmit failed: BadInputsUTxO"])

    def test_notes_of_a_successful_submit_are_logged(self):
        """A resend inside p1-batch.sh must show up in the gateway log, not only a failure."""
        logs = []
        ok = "OK: gateway A batch %s is in a block: tx %s (size 1500 bytes)" % (self.H, txid_of(5))
        script = ("echo '%s'; echo '  the transaction was lost (not in a block, not in the mempool): sent the same "
                  "transaction again' >&2" % ok)
        sub = gateway.make_submit("command", "sh -c \"%s\" x" % script, log=logs.append)
        self.assertEqual(sub("/x/batch-1.json", self.H), txid_of(5))
        self.assertEqual(logs, ["note from the submit command for batch-1.json: the transaction was lost (not in a "
                                "block, not in the mempool): sent the same transaction again"])
        logs.clear()
        quiet_ok = gateway.make_submit("command", "sh -c \"echo '%s'\" x" % ok, log=logs.append)
        quiet_ok("/x/batch-2.json", self.H)
        self.assertEqual(logs, [])                              # nothing on stderr: nothing extra in the log
        many = gateway.make_submit("command", "sh -c 'for i in 1 2 3 4 5 6 7; do echo n$i >&2; done' x",
                                   log=logs.append)
        many("/x/b.json", self.H)
        self.assertEqual([m.split(": ")[-1] for m in logs], ["n3", "n4", "n5", "n6", "n7"])   # the last 5 only


class TestFollowToFinal(FollowCase):
    def test_in_a_block_then_final(self):
        name = self.send_batches(1)[0]
        self.assertEqual(self.status(name), "settling")
        self.assertEqual(self.tx(name)["txid"], self.sub.txids[0])
        self.assertEqual(self.gw.pending_files(), [])
        self.chain.add(self.sub.txids[0])
        self.gw.check_settling()
        self.assertEqual(self.status(name), "settling")
        self.assertEqual(self.tx(name)["block"], 1000)                  # the tip block when it was first seen
        self.chain.advance(K - 2)                                       # depth K - 1
        self.gw.check_settling()
        self.assertEqual(self.status(name), "settling")
        self.chain.advance(1)                                           # depth K
        self.gw.check_settling()
        self.assertEqual(self.status(name), "final")
        self.assertEqual(self.gw.stats["final"], 1)
        self.assertTrue(any(m.startswith("final: ") for m in self.logs))
        self.assertEqual(len(self.sub.calls), 1)                        # never sent again
        self.assertEqual(self.gw.settling_files(), [])

    def test_vanished_batch_is_sent_again_once_oldest_first(self):
        names = self.send_batches(2)
        for t in self.sub.txids:
            self.chain.add(t)
        self.gw.check_settling()
        for t in self.sub.txids[:2]:                                    # the block of both is replaced
            self.chain.drop(t)
        self.gw.check_settling()                                        # missing for the first time: wait
        self.clock.t += 59
        self.gw.check_settling()
        self.assertEqual(len(self.sub.calls), 2)                        # inside the grace time: nothing yet
        self.clock.t += 2
        self.gw.check_settling()
        self.assertEqual(len(self.sub.calls), 2)                        # the check only marks them: nothing submitted
        self.assertEqual([self.status(n) for n in names], ["pending", "pending"])
        self.assertTrue(self.gw.wake.is_set())                          # and the sender is woken
        self.gw.send_pending()
        self.assertEqual([c[0] for c in self.sub.calls[2:]], names)     # sent again, oldest first
        self.assertEqual(len([m for m in self.logs if m.startswith("sent again: " + names[0])]), 1)
        self.assertEqual(len([m for m in self.logs if m.startswith("sent: ")]), 2)    # demo.sh counts these
        self.assertTrue(any("no longer in the chain (block replaced): sending it again" in m for m in self.logs))
        self.assertEqual(self.gw.stats["resent"], 2)
        self.assertEqual(self.tx(names[0])["txid"], self.sub.txids[2])  # the new transaction is followed
        self.assertEqual(self.tx(names[0])["resends"], 1)
        self.assertEqual(self.tx(names[0])["block"], None)              # depth counts from the new block
        self.gw.check_settling()                                        # new transactions not in a block yet
        self.assertEqual(len(self.sub.calls), 4)                        # waits for its own grace time first
        self.chain.advance(K)
        self.chain.add(self.sub.txids[2])
        self.chain.add(self.sub.txids[3])
        self.gw.check_settling()
        self.assertEqual(self.tx(names[0])["block"], 1060)
        self.chain.advance(K)
        self.gw.check_settling()
        self.assertEqual([self.status(n) for n in names], ["final", "final"])
        self.assertEqual(len(self.sub.calls), 4)

    def test_every_resend_uses_the_same_file_and_hash(self):
        name = self.send_batches(1)[0]
        self.gw.check_settling()
        self.clock.t += 61
        self.gw.check_settling()
        self.gw.send_pending()
        self.clock.t += 61
        self.gw.check_settling()
        self.gw.send_pending()
        self.assertEqual(len(self.sub.calls), 2)
        self.assertEqual(self.sub.calls[0], self.sub.calls[1])
        self.assertIn(self.sub.calls[0][1], name)

    def test_restart_keeps_the_batches_that_are_not_final(self):
        name = self.send_batches(1)[0]
        self.chain.add(self.sub.txids[0])
        self.gw.check_settling()
        gw2 = self.make()                                               # "restart": new objects, same outbox
        self.assertEqual(gw2.pending_files(), [])
        self.assertEqual([os.path.basename(p) for p in gw2.settling_files()], [name])
        self.chain.advance(K)
        gw2.check_settling()
        self.assertEqual(self.status(name), "final")
        self.assertEqual(len(self.sub.calls), 1)

    def test_refused_when_sent_again_goes_to_dead(self):
        name = self.send_batches(1)[0]
        self.gw.check_settling()
        self.clock.t += 61
        self.sub.answer = "refused"                                     # revoked in the meantime
        self.gw.check_settling()
        self.gw.send_pending()
        self.assertFalse(os.path.exists(os.path.join(self.dir, name)))
        dead = os.listdir(os.path.join(self.dir, "dead"))
        self.assertEqual(sorted(dead), [name, name + ".status", name + ".tx"])
        self.assertEqual(self.gw.settling_files(), [])
        self.assertEqual(self.gw.stats["dead"], 1)
        self.assertTrue(any("DEAD LETTER" in m and "refused when sent again" in m for m in self.logs))

    def test_failed_resend_keeps_the_order_and_ends_in_dead(self):
        names = self.send_batches(2)
        self.gw = self.make(max_tries=2)
        self.gw.check_settling()
        self.clock.t += 61
        self.sub.answer = False                                         # both have been missing for 61 s
        calls = len(self.sub.calls)
        self.gw.check_settling()                                        # both are marked, nothing is submitted
        self.assertEqual(len(self.sub.calls), calls)
        self.gw.send_pending()                                          # the oldest fails: the run stops
        self.assertEqual(len(self.sub.calls), calls + 1)
        self.assertEqual(self.status(names[0]), "pending 1")
        self.gw.send_pending()                                          # second failure: dead; the next one is tried
        self.assertTrue(os.path.exists(os.path.join(self.dir, "dead", names[0])))
        self.assertEqual([os.path.basename(p) for p in self.gw.pending_files()], [names[1]])   # tried next, failed once
        self.assertEqual(self.status(names[1]), "pending 1")

    def test_a_kupo_problem_is_not_a_replaced_block(self):
        self.send_batches(1)
        self.gw.check_settling()
        self.chain.down = True
        self.clock.t += 1000
        self.gw.check_settling()
        self.gw.check_settling()
        self.assertEqual(len(self.sub.calls), 1)
        self.assertEqual(len([m for m in self.logs if "cannot check" in m]), 1)    # logged once
        self.chain.down = False
        self.chain.add(self.sub.txids[0])
        self.gw.check_settling()
        self.assertEqual(len(self.sub.calls), 1)

    def test_kupo_behind_the_node_is_not_trusted(self):
        self.send_batches(1)
        self.chain.health = lambda: {"checkpoint": self.chain.slot - 100, "node_tip": self.chain.slot,
                                     "connected": True, "synced": 0.5}
        self.clock.t += 1000
        self.gw.check_settling()
        self.assertEqual(len(self.sub.calls), 1)
        self.assertTrue(any("slots behind" in m for m in self.logs))

    def test_without_a_txid_or_a_view_the_batch_is_just_sent(self):
        self.sub.answer = True                                          # the command printed no transaction id
        name = self.send_batches(1)[0]
        self.assertEqual(self.status(name), "sent")
        self.assertFalse(os.path.exists(os.path.join(self.dir, name + ".tx")))
        self.assertEqual(self.gw.settling_files(), [])
        shutil.rmtree(self.dir)
        os.makedirs(self.dir)
        self.sub.answer = None
        gw = self.make(with_view=False)                                 # no --kupo
        name = self.send_batches(1, gw)[0]
        self.assertEqual(self.status(name), "sent")
        gw.check_settling()                                             # does nothing, does not fail

    def test_old_outbox_with_sent_status_is_left_alone(self):
        name = self.send_batches(1)[0]
        with open(os.path.join(self.dir, name + ".status"), "w") as f:
            f.write("sent")
        os.remove(os.path.join(self.dir, name + ".tx"))
        self.clock.t += 1000
        self.gw.check_settling()
        self.assertEqual(len(self.sub.calls), 1)
        self.assertEqual(self.gw.pending_files(), [])


class TestResendDoesNotBlock(FollowCase):
    def test_the_check_never_takes_the_send_lock(self):
        """A resend can take 100 s: the checking must not wait for the sender, nor hold it up."""
        self.send_batches(1)
        self.gw.check_settling()
        self.clock.t += 61
        self.assertTrue(self.gw.send_lock.acquire(False))               # "the sender is busy submitting"
        try:
            t = threading.Thread(target=self.gw.check_settling)
            t.start()
            t.join(5)
            self.assertFalse(t.is_alive())
        finally:
            self.gw.send_lock.release()
        self.assertEqual(len(self.sub.calls), 1)                        # the check submitted nothing

    def test_a_new_batch_goes_out_while_an_old_one_waits_for_its_resend(self):
        names = self.send_batches(1)
        self.gw.check_settling()
        self.clock.t += 61
        self.gw.check_settling()                                        # batch 1 pending again
        self.gw.add_reading(reading(50))                                # batch 2 is new
        self.gw.send_pending()
        self.assertEqual([c[0][:12] for c in self.sub.calls], ["batch-000001", "batch-000001", "batch-000002"])
        self.assertEqual(self.gw.pending_files(), [])

    def test_resend_count_goes_on_and_log_lines_differ(self):
        name = self.send_batches(1)[0]
        for n in (1, 2):
            self.gw.check_settling()
            self.clock.t += 61
            self.gw.check_settling()
            self.gw.send_pending()
            self.assertEqual(self.tx(name)["resends"], n)
            self.assertEqual(self.status(name), "settling")
        self.assertEqual(self.gw.stats["resent"], 2)
        self.assertEqual(len([m for m in self.logs if m.startswith("sent again: ")]), 2)
        self.assertEqual(len([m for m in self.logs if m.startswith("sent: ")]), 1)

    def test_a_resend_survives_a_restart(self):
        name = self.send_batches(1)[0]
        self.gw.check_settling()
        self.clock.t += 61
        self.gw.check_settling()
        gw2 = self.make()                                               # restart: the batch is pending with a .tx file
        gw2.send_pending()
        self.assertEqual(self.tx(name)["resends"], 1)
        self.assertEqual(len(self.sub.calls), 2)

    def test_the_old_transaction_still_in_the_mempool(self):
        name = self.send_batches(1)[0]
        self.gw.check_settling()
        self.clock.t += 61
        self.gw.check_settling()
        self.sub.answer = self.tx(name)["txid"]                         # "already sent: ... is transaction X"
        self.gw.send_pending()
        self.assertEqual(self.status(name), "settling")
        self.assertEqual(self.tx(name)["resends"], 0)
        self.assertEqual(self.gw.stats["resent"], 0)


class TestFinalNeverEarly(FollowCase):
    def test_first_seen_late_is_counted_from_the_tip_of_that_moment(self):
        name = self.send_batches(1)[0]
        self.chain.add(self.sub.txids[0])                               # in the block at 1000 ...
        self.chain.advance(100)                                         # ... but the gateway looks 100 blocks later
        self.gw.check_settling()
        self.assertEqual(self.tx(name)["block"], 1100)                  # not 1000 and not an estimate
        self.assertEqual(self.status(name), "settling")                 # an estimate would have said "final" now
        self.chain.advance(K - 1)
        self.gw.check_settling()
        self.assertEqual(self.status(name), "final")


class TestDeadLetterChecksTheChain(FollowCase):
    def failing_resend(self, max_tries=2):
        """A batch that was in the chain once, vanished, and whose resends keep failing."""
        self.gw = self.make(max_tries=max_tries)
        name = self.send_batches(1)[0]
        txid = self.sub.txids[0]
        self.chain.add(txid)
        self.gw.check_settling()
        self.chain.drop(txid)
        self.gw.check_settling()
        self.clock.t += 61
        self.gw.check_settling()
        self.sub.answer = False
        return name, txid

    def test_transaction_is_in_the_chain_after_all(self):
        name, txid = self.failing_resend()
        self.gw.send_pending()                                          # try 1
        self.chain.add(txid)                                            # the "failed" submit had worked after all
        self.gw.send_pending()                                          # try 2 = max_tries
        self.assertEqual(self.status(name), "settling")
        self.assertTrue(os.path.exists(os.path.join(self.dir, name)))
        self.assertEqual(self.gw.stats["dead"], 0)
        self.assertTrue(any("is in the chain: following it" in m for m in self.logs))
        self.chain.advance(K)
        self.gw.check_settling()
        self.assertEqual(self.status(name), "final")

    def test_not_in_the_chain_goes_to_dead(self):
        name, txid = self.failing_resend()
        self.gw.send_pending()
        self.gw.send_pending()
        self.assertTrue(os.path.exists(os.path.join(self.dir, "dead", name)))
        self.assertEqual(self.gw.stats["dead"], 1)

    def test_kupo_down_decides_later(self):
        name, txid = self.failing_resend()
        self.gw.send_pending()
        self.chain.down = True
        self.gw.send_pending()                                          # max_tries reached, but Kupo cannot say
        self.assertFalse(os.path.exists(os.path.join(self.dir, "dead", name)))
        self.assertEqual(self.status(name), "pending 2")
        self.chain.down = False
        self.gw.send_pending()
        self.assertTrue(os.path.exists(os.path.join(self.dir, "dead", name)))

    def test_a_batch_that_was_never_in_the_chain_goes_to_dead_at_once(self):
        self.sub.answer = False
        self.gw = self.make(max_tries=1)
        self.gw.add_reading(reading(1))
        self.gw.send_pending()
        self.assertEqual(self.gw.stats["dead"], 1)


class TestChainView(unittest.TestCase):
    def test_pruning_kupo_is_noticed_through_the_metadata(self):
        chain, logs = FakeChain(), []
        view = confirm.ChainView(chain, chain, logs.append, FakeClock())
        obj = layout.build_batch("GW01", 1, [reading(1)])
        chain.metadata[(5000, txid_of(1))] = obj              # no outputs listed, but the metadata is there
        self.assertIsNone(view.locate(txid_of(1)))            # without a hint nothing is known
        self.assertEqual(view.locate(txid_of(1), 5000), (5000, "aa"))
        view.locate(txid_of(1), 5000)
        self.assertEqual(len([m for m in logs if "prune" in m]), 1)
        self.assertIsNone(view.locate(txid_of(2), 5000))      # really missing

    def test_depth_and_first_block(self):
        chain = FakeChain()
        view = confirm.ChainView(chain, chain, quiet, FakeClock())
        self.assertIsNone(view.refresh())
        self.assertEqual(view.new_block(chain.slot), 1000)
        self.assertEqual(view.depth(1000), 1)
        chain.advance(9)
        view.refresh()
        self.assertEqual(view.depth(1000), 10)
        self.assertIsNone(view.depth(None))

    def test_a_late_sighting_is_never_stored_as_an_exact_block(self):
        """Seen far behind the tip (a restart): the tip block is stored, so final can only be late."""
        chain, clock = FakeChain(), FakeClock()
        view = confirm.ChainView(chain, chain, quiet, clock)
        old_slot = chain.slot                                           # the transaction is in the block at 1000
        chain.advance(100)                                              # 100 blocks later the gateway looks
        view.refresh()
        block = view.new_block(old_slot)
        self.assertEqual(block, chain.block)                            # not 1000, not an estimate below the real one
        self.assertGreaterEqual(block, 1000)                            # never older than the real block
        self.assertEqual(view.depth(block), 1)                          # counted from now: 59 more blocks to final
        chain.advance(59)
        view.refresh()
        self.assertEqual(view.depth(block), 60)

    def test_an_old_tip_is_not_used(self):
        chain, clock = FakeChain(), FakeClock()
        view = confirm.ChainView(chain, chain, quiet, clock)
        view.refresh()
        clock.t += confirm.TIP_FRESH_S + 1                              # the tip has not been refreshed
        self.assertIsNone(view.new_block(chain.slot))                   # wait for a fresh look
        view.refresh()
        self.assertEqual(view.new_block(chain.slot), 1000)

    def test_refresh_says_why_not(self):
        chain = FakeChain()
        view = confirm.ChainView(chain, chain, quiet, FakeClock())
        chain.down = True
        self.assertIn("Kupo does not answer", view.refresh())
        chain.down = False
        chain.get = lambda: (_ for _ in ()).throw(RuntimeError("tip query failed"))
        self.assertIn("no node tip", view.refresh())


class TestFindTransaction(unittest.TestCase):
    def test_slot_and_header_of_the_first_output(self):
        k = kupo_reader.Kupo()
        paths = []

        def fake_get(path, **params):
            paths.append(path)
            return [{"created_at": {"slot_no": 77, "header_hash": "ff"}, "output_index": 0},
                    {"created_at": {"slot_no": 77, "header_hash": "ff"}, "output_index": 1}], {}
        k._get = fake_get
        self.assertEqual(k.find_transaction(txid_of(3)), (77, "ff"))
        self.assertEqual(paths, ["/matches/*@" + txid_of(3)])
        k._get = lambda path, **params: ([], {})
        self.assertIsNone(k.find_transaction(txid_of(3)))


class TestCheckBatches(unittest.TestCase):
    """check_batches.py on small outboxes: one written like the new gateway does, one like the old gateway did."""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="check-test-")
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.chain = FakeChain()
        self.chain.block, self.chain.slot = 1000, 5000            # tip

    def write_batches(self, n, first_seq=1):
        """n batch files of 2 readings each, with status "pending". Returns [(file name, batch object)]."""
        gw = gateway.Gateway(self.dir, 2, 10, lambda p, h: False, clock=FakeClock(), log=quiet)
        for seq in range(first_seq, first_seq + 2 * n):
            gw.add_reading(reading(seq))
        names = sorted(f for f in os.listdir(self.dir) if f.startswith("batch-") and f.endswith(".json"))[-n:]
        out = []
        for name in names:
            with open(os.path.join(self.dir, name)) as f:
                out.append((name, json.load(f)))
        return out

    def set_status(self, name, status, tx=None):
        with open(os.path.join(self.dir, name + ".status"), "w") as f:
            f.write(status)
        if tx:
            with open(os.path.join(self.dir, name + ".tx"), "w") as f:
                json.dump(tx, f)

    def put_on_chain(self, obj, slot, txid):
        self.chain.listed.append((slot, txid, obj))
        self.chain.metadata[(slot, txid)] = obj
        self.chain.txs[txid] = (slot, "aa")

    def run_check(self, gateway_id=None):
        entries = check_batches.read_outbox(self.dir, gateway_id)
        check_batches.classify(entries, check_batches.Chain(self.chain), K, self.chain.get())
        return {e["name"]: e for e in entries}

    def groups(self, result):
        count = {g: 0 for g in check_batches.GROUPS}
        for e in result.values():
            count[e["group"]] += 1
        return count

    def test_new_outbox_counts_every_group(self):
        b = self.write_batches(5)
        self.put_on_chain(b[0][1], 4000, txid_of(1))
        self.set_status(b[0][0], "final", {"txid": txid_of(1), "slot": 4000, "block": 800})      # 201 deep
        self.put_on_chain(b[1][1], 4990, txid_of(2))
        self.set_status(b[1][0], "settling", {"txid": txid_of(2), "slot": 4990, "block": 990})   # 11 deep
        self.set_status(b[2][0], "pending")                                                      # never sent
        self.set_status(b[3][0], "settling", {"txid": txid_of(4), "slot": 4995, "block": 999})   # not on chain
        dead = os.path.join(self.dir, "dead")
        os.makedirs(dead)
        os.replace(os.path.join(self.dir, b[4][0]), os.path.join(dead, b[4][0]))
        with open(os.path.join(dead, b[4][0] + ".status"), "w") as f:
            f.write("dead 1")
        result = self.run_check()
        self.assertEqual(self.groups(result), {"final": 1, "settling": 1, "pending": 1, "dead": 1, "LOST": 1})
        self.assertEqual(result[b[0][0]]["found"], "transaction id")
        self.assertEqual(result[b[1][0]]["depth"], 11)
        self.assertEqual(result[b[3][0]]["group"], "LOST")
        text = check_batches.report(list(result.values()), K, False)
        self.assertIn("LOST", text)
        self.assertIn(b[3][0], text)
        self.assertIn("refused or failed too often (some may have been sent before); not in the chain", text)

    def test_old_outbox_without_txid_is_matched_by_hash_and_content(self):
        b = self.write_batches(4)
        for name, _ in b:
            self.set_status(name, "sent")                         # what the old gateway wrote: no .tx at all
        self.put_on_chain(b[0][1], 1000, txid_of(1))              # same bytes: found by hash, deep (estimated)
        self.put_on_chain(b[1][1], 4950, txid_of(2))              # found by hash, recent
        # batch 3 is on the chain only inside other batches (other batch numbers, so other hashes): by content
        for i, group in enumerate((b[2][1], b[3][1])):
            readings = layout.decode_batch(group)
            half = [dict(sensor_id=r["sensor"], seq=r["seq"], ts=r["ts"], kind=r["kind"], value=r["value"],
                         scale=r["scale"]) for r in readings]
            other = layout.build_batch("GW01", 90 + i, half[:1] if i else half)
            self.put_on_chain(other, 4900 + i, txid_of(10 + i))
        result = self.run_check()
        found = [result[name]["found"] for name, _ in b]
        self.assertEqual(found, ["hash", "hash", "content", ""])  # the last has only half of its readings
        self.assertEqual(self.groups(result), {"final": 1, "settling": 2, "pending": 0, "dead": 0, "LOST": 1})
        self.assertEqual(result[b[3][0]]["group"], "LOST")

    def test_a_batch_on_the_chain_twice_is_reported(self):
        b = self.write_batches(2)
        for i, (name, obj) in enumerate(b):
            self.put_on_chain(obj, 4000 + i, txid_of(1 + i))
            self.set_status(name, "settling", {"txid": txid_of(1 + i), "slot": 4000 + i, "block": 800})
        text = check_batches.report(list(self.run_check().values()), K, False)
        self.assertIn("OK: no batch is on the chain twice", text)
        self.put_on_chain(b[0][1], 4500, txid_of(9))           # the same batch in a second transaction
        result = self.run_check()
        self.assertEqual(result[b[0][0]]["copies"], 2)
        self.assertEqual(result[b[1][0]]["copies"], 1)
        text = check_batches.report(list(result.values()), K, False)
        self.assertIn("TWICE: 1 batches", text)
        self.assertIn("%s (2 transactions)" % b[0][0], text)

    def test_gateway_id_filter(self):
        self.write_batches(2)
        self.assertEqual(len(self.run_check("GW01")), 2)
        self.assertEqual(len(self.run_check("GW02")), 0)

    def test_status_word_pending_with_tries_is_pending(self):
        b = self.write_batches(1)
        self.set_status(b[0][0], "pending 3")
        self.assertEqual(self.groups(self.run_check())["pending"], 1)


if __name__ == "__main__":
    unittest.main()
