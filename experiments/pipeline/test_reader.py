"""Tests for reader.py and server.py with a simulated Kupo and a simulated node tip (no chain, no network).

Run:  python3 -m unittest -v test_reader   (in this folder; Python 3.8 or newer)
"""
import json
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import layout
import reader
import server

ADDR_A = "addr_test1_gateway_a"
ADDR_B = "addr_test1_gateway_b"
ADDR_X = "addr_test1_somebody_else"
GATEWAYS = {"GW01": ADDR_A, "GW02": ADDR_B}
POLICY = "4007b3caeeeb9cc4d131463e3972553aadb29ca6a54cde26216bbc85"


def make_obj(gw="GW01", no=1, t0=1000, groups=None):
    groups = groups if groups is not None else [["AGRI_001", 1, 100, [[0, 2450, 1], [5, 2460, 2]]]]
    return {"1000": [1, gw, no, t0, groups]}


class FakeClock:
    def __init__(self, t=5000.0):
        self.t = t

    def __call__(self):
        return self.t


class FakeKupo:
    """Chain data kept as a list of transactions; answers like Kupo (health, matches, batch)."""

    def __init__(self):
        self.txs = []          # dicts: slot, txid, header, owner, receipts, obj
        self.down = False
        self.checkpoint = 0

    def add(self, slot, txid, obj, owner=ADDR_A, receipts=1, header=None):
        self.txs.append({"slot": slot, "txid": txid, "header": header or ("h%d" % slot), "owner": owner,
                         "receipts": receipts, "obj": obj})
        self.checkpoint = max(self.checkpoint, slot)

    def remove(self, txid):
        self.txs = [t for t in self.txs if t["txid"] != txid]

    def _check(self):
        if self.down:
            raise urllib.error.URLError("connection refused")

    def health(self):
        self._check()
        return {"checkpoint": self.checkpoint, "node_tip": self.checkpoint, "connected": True, "synced": 1.0}

    def matches(self, after_slot):
        self._check()
        out = []
        for t in sorted(self.txs, key=lambda t: t["slot"]):
            if t["slot"] > after_slot:
                assets = {"%s.%s" % (POLICY, reader.RECEIPT_HEX): t["receipts"]} if t["receipts"] else {}
                for idx in (0, 1):       # output 1 is some other output (must be ignored)
                    out.append({"transaction_id": t["txid"], "output_index": idx,
                                "address": t["owner"] if idx == 0 else ADDR_X,
                                "value": {"coins": 1000000, "assets": assets if idx == 0 else {}},
                                "created_at": {"slot_no": t["slot"], "header_hash": t["header"]}})
        return out

    def batch(self, slot, txid):
        self._check()
        for t in self.txs:
            if t["txid"] == txid and t["slot"] == slot:
                if t["obj"] is None:
                    return None, None, t["header"]
                return t["obj"], layout.batch_hash(layout.dump(t["obj"])), t["header"]
        return None, None, None


class FakeTip:
    def __init__(self, block=1000, slot=5000):
        self.block, self.slot, self.down = block, slot, False

    def get(self):
        if self.down:
            raise RuntimeError("node not reachable")
        return {"block": self.block, "slot": self.slot, "hash": "tip%d" % self.block}

    def advance(self, blocks):
        self.block += blocks
        self.slot += blocks * 5


class ReaderTest(unittest.TestCase):
    def setUp(self):
        self.kupo, self.tip, self.clock = FakeKupo(), FakeTip(), FakeClock()
        self.logs = []
        self.rd = self.make()

    def make(self, **kw):
        args = dict(gateways=GATEWAYS, final_depth=60, window=300, silent_after=30, clock=self.clock,
                    log=self.logs.append)
        args.update(kw)
        return reader.Reader(self.kupo, self.tip, **args)

    def poll(self, rd=None):
        rd = rd or self.rd
        self.assertTrue(rd.poll_tip())
        self.assertTrue(rd.poll_once())

    def batch(self, state, i=0):
        return state["batches"][i]

    # ---------------------------------------------------------- normal flow

    def test_normal_flow(self):
        self.poll()                                    # empty chain
        self.assertEqual(self.rd.state()["counts"]["batches"], 0)
        self.kupo.add(4990, "t1", make_obj(no=1, t0=1000), receipts=7)
        self.kupo.add(4995, "t2", make_obj(no=2, t0=1010, groups=[["AGRI_001", 1, 100, [[0, 2470, 3]]],
                                                                    ["AGRI_002", 2, 10, [[1, 655, 1]]]]), receipts=8)
        self.poll()
        s = self.rd.state()
        self.assertEqual(s["counts"]["batches"], 2)
        self.assertEqual(s["counts"]["readings"], 4)
        b = self.batch(s)                              # newest first
        self.assertEqual((b["txid"], b["slot"], b["receipts"], b["readings"]), ("t2", 4995, 8, 2))
        self.assertEqual(b["signer"], ADDR_A)          # output #0, not output #1
        self.assertEqual(b["signer_name"], "GW01")
        self.assertEqual(b["hash"], layout.batch_hash(layout.dump(make_obj(no=2, t0=1010, groups=[
            ["AGRI_001", 1, 100, [[0, 2470, 3]]], ["AGRI_002", 2, 10, [[1, 655, 1]]]]))))
        self.assertEqual(b["warnings"], [])
        sens = {x["sensor"]: x for x in s["sensors"]}
        self.assertEqual(sorted(sens), ["AGRI_001", "AGRI_002"])
        self.assertEqual(sens["AGRI_001"]["count"], 3)
        self.assertEqual(sens["AGRI_001"]["latest"], 24.7)
        self.assertEqual(sens["AGRI_001"]["unit"], "°C")
        self.assertEqual(sens["AGRI_002"]["text"], "65.5")
        self.assertEqual([p[1] for p in sens["AGRI_001"]["points"]], [24.5, 24.6, 24.7])
        gw = {g["name"]: g for g in s["gateways"]}
        self.assertEqual((gw["GW01"]["batches"], gw["GW01"]["readings"], gw["GW01"]["receipts"]), (2, 4, 8))
        self.assertEqual(gw["GW02"]["batches"], 0)
        self.assertTrue(s["kupo"]["ok"])

    def test_no_double_counting_when_window_is_read_again(self):
        self.kupo.add(4990, "t1", make_obj())
        for _ in range(4):
            self.poll()
        s = self.rd.state()
        self.assertEqual((s["counts"]["batches"], s["counts"]["readings"]), (1, 2))

    def test_same_readings_in_two_batches_count_once(self):
        # a gateway that sent the same batch twice (at-least-once) makes two transactions
        self.kupo.add(4990, "t1", make_obj())
        self.kupo.add(4992, "t2", make_obj())
        self.poll()
        s = self.rd.state()
        self.assertEqual(s["counts"]["batches"], 2)
        self.assertEqual(s["sensors"][0]["count"], 2)

    # ---------------------------------------------------------- foreign layouts

    def test_foreign_layout_skipped_counted_logged_once(self):
        old = {"1000": {"t": "2026-11-12T04:19:24Z", "temp": 2450, "scale": 100, "sensor": "AGRI_001"}}
        wrong_list = {"1000": [2, "GW01", 1, 5, []]}           # list, but another version
        broken = {"1000": [1, "GW01", 1, 5, [["S", 9, 100, [[0, 1, 1]]]]]}   # unknown kind code
        self.kupo.add(100, "o1", old)
        self.kupo.add(101, "o2", wrong_list)
        self.kupo.add(102, "o3", broken)
        self.kupo.add(103, "n1", None)                          # no metadata at all
        self.kupo.add(4990, "t1", make_obj())
        self.poll()
        self.poll()
        s = self.rd.state()
        self.assertEqual(s["counts"]["skipped_foreign"], 3)
        self.assertEqual(s["counts"]["other_transactions"], 1)
        self.assertEqual(s["counts"]["batches"], 1)
        self.assertEqual(len([m for m in self.logs if "not our layout" in m]), 1)

    def test_health_answers_of_kupo(self):
        js = ('{"connection_status":"connected","most_recent_checkpoint":5700,"most_recent_node_tip":5701,'
              '"seconds_since_last_block":4,"network_synchronization":1.00000,"configuration":{"indexes":"installed"}}')
        prom = ("# TYPE kupo_connection_status gauge\nkupo_connection_status  1.0\n# TYPE kupo_most_recent_checkpoint counter\n"
                "kupo_most_recent_checkpoint  5700\nkupo_most_recent_node_tip  5701\nkupo_network_synchronization  1.0\n")
        for text in (js, prom):
            self.assertEqual(reader.parse_health(text), {"checkpoint": 5700, "node_tip": 5701, "connected": True, "synced": 1.0})
        self.assertFalse(reader.parse_health('{"connection_status":"disconnected","most_recent_checkpoint":null}')["connected"])

    def test_parse_our_batch(self):
        got = reader.parse_our_batch(make_obj())
        self.assertEqual(got["gateway"], "GW01")
        self.assertEqual(len(got["readings"]), 2)
        for bad in ({"1000": {"a": 1}}, {"1000": [1, "G", 1, 1]}, {"1000": [1, "G", True, 1, []]},
                    {"1000": [1, "G", 1, 1, [["S", 1, 0, []]]]}, {"1000": [1, "G", 1, 1, [["S", 1, 100, [[1, 2]]]]]},
                    {"1000": [1, "G", 1, 1, [["S", 1, 100, [[1, 2.5, 3]]]]]}, {"674": 1}):
            with self.assertRaises(ValueError):
                reader.parse_our_batch(bad)

    # ---------------------------------------------------------- rollback

    def test_rollback_detected_and_readings_dropped(self):
        self.kupo.add(4990, "t1", make_obj(no=1))
        self.kupo.add(4996, "t2", make_obj(no=2, groups=[["AGRI_002", 2, 10, [[0, 500, 1]]]]))
        self.poll()
        self.assertEqual(len(self.rd.state()["sensors"]), 2)
        self.kupo.remove("t2")                       # the block is gone
        self.poll()
        s = self.rd.state()
        self.assertEqual(self.batch(s)["status"], "rolled back")
        self.assertIsNone(self.batch(s)["depth"])
        self.assertEqual(s["counts"]["rolled_back"], 1)
        self.assertEqual([x["sensor"] for x in s["sensors"]], ["AGRI_001"])
        self.assertEqual(s["counts"]["readings"], 2)
        # the same transaction comes back in another block: counted again from depth 1
        self.kupo.add(5002, "t2", make_obj(no=2, groups=[["AGRI_002", 2, 10, [[0, 500, 1]]]]))
        self.tip.advance(1)
        self.poll()
        s = self.rd.state()
        self.assertEqual(self.batch(s)["status"], "in a block")
        self.assertEqual(self.batch(s)["slot"], 5002)
        self.assertEqual(self.batch(s)["reorgs"], 1)
        self.assertEqual(len(s["sensors"]), 2)

    def test_rollback_found_outside_the_window(self):
        # the batch is older than the window; the extra question about it still notices the rollback
        rd = self.make(window=20)
        self.kupo.add(4960, "t1", make_obj(no=1))
        self.poll(rd)
        self.kupo.add(5000, "t9", make_obj(no=9))      # moves the cursor ahead: slot 4960 is outside the window now
        self.poll(rd)
        self.kupo.remove("t1")
        self.poll(rd)
        states = {b["txid"]: b["status"] for b in rd.state()["batches"]}
        self.assertEqual(states["t1"], "rolled back")
        self.assertEqual(states["t9"], "in a block")

    def test_changed_header_restarts_the_depth(self):
        self.poll()
        self.kupo.add(5000, "t1", make_obj(), header="aaa")
        self.poll()
        self.tip.advance(10)
        self.poll()
        self.assertEqual(self.batch(self.rd.state())["depth"], 11)
        # the same transaction is now in another block, at a new slot near the tip
        self.kupo.txs[0].update({"header": "bbb", "slot": 5048})
        self.kupo.checkpoint = 5048
        self.poll()
        b = self.batch(self.rd.state())
        self.assertEqual((b["header"], b["slot"], b["reorgs"], b["status"]), ("bbb", 5048, 1, "in a block"))
        self.assertEqual(b["depth"], 1)

    def test_competing_block_in_the_same_slot_keeps_the_depth(self):
        self.poll()
        self.kupo.add(5000, "t1", make_obj(), header="aaa")
        self.poll()
        self.tip.advance(10)
        self.poll()
        self.kupo.txs[0]["header"] = "bbb"
        self.poll()
        b = self.batch(self.rd.state())
        self.assertEqual((b["header"], b["reorgs"], b["depth"]), ("bbb", 1, 11))

    def test_kupo_behind_does_not_look_like_a_rollback(self):
        self.kupo.add(4990, "t1", make_obj())
        self.poll()
        self.kupo.checkpoint = 1000                  # Kupo is rebuilding its database and has not reached slot 4990
        self.kupo.remove("t1")
        self.poll()
        self.assertEqual(self.batch(self.rd.state())["status"], "in a block")

    # ---------------------------------------------------------- depth, final, estimate

    def test_depth_counting_and_final(self):
        self.poll()                                  # first round done: later batches are "first seen live"
        self.kupo.add(5000, "t1", make_obj())
        self.poll()
        b = self.batch(self.rd.state())
        self.assertEqual((b["block"], b["depth"], b["status"], b["estimate"]), (1000, 1, "in a block", False))
        self.tip.advance(4)
        self.poll()
        self.assertEqual(self.batch(self.rd.state())["depth"], 5)
        self.tip.advance(54)                          # tip block 1058: depth 59
        self.poll()
        b = self.batch(self.rd.state())
        self.assertEqual((b["depth"], b["status"]), (59, "in a block"))
        self.assertAlmostEqual(b["progress"], 59 / 60.0)
        self.tip.advance(1)                           # depth 60
        self.poll()
        b = self.batch(self.rd.state())
        self.assertEqual((b["depth"], b["status"], b["progress"]), (60, "final", 1.0))
        self.assertEqual(self.rd.state()["counts"]["final"], 1)

    def test_final_depth_is_configurable_and_final_is_kept(self):
        rd = self.make(final_depth=3)
        self.poll(rd)
        self.kupo.add(5000, "t1", make_obj())
        self.poll(rd)
        self.tip.advance(2)
        self.poll(rd)
        self.assertEqual(self.batch(rd.state())["status"], "final")
        self.kupo.remove("t1")                        # a final batch is not asked about again
        self.poll(rd)
        self.assertEqual(self.batch(rd.state())["status"], "final")

    def test_batches_found_at_start_are_estimates(self):
        # the node tip is block 1000 at slot 5000: 5 slots per block
        self.kupo.add(4000, "t1", make_obj(no=1))
        self.kupo.add(4900, "t2", make_obj(no=2))
        self.poll()
        s = self.rd.state()
        old, new = s["batches"][1], s["batches"][0]
        self.assertTrue(old["estimate"] and new["estimate"])
        self.assertEqual(s["counts"]["estimate"], 2)
        # (5000 - 4000) slots at 0.2 blocks per slot = 200 blocks back
        self.assertEqual(old["depth"], 201)
        self.assertEqual(old["status"], "final")
        self.assertEqual(new["depth"], 21)
        self.assertEqual(new["status"], "in a block")
        self.tip.advance(10)                          # the estimate keeps counting with the real tip
        self.poll()
        self.assertEqual(self.rd.state()["batches"][0]["depth"], 31)
        # a batch that arrives afterwards is not an estimate
        self.tip.advance(1)
        self.kupo.add(self.tip.slot, "t3", make_obj(no=3))
        self.poll()
        self.assertFalse(self.rd.state()["batches"][0]["estimate"])

    def test_batch_found_late_is_an_estimate(self):
        self.poll()
        self.kupo.add(4000, "t1", make_obj())          # appears long after its slot (for example after an outage)
        self.poll()
        self.assertTrue(self.batch(self.rd.state())["estimate"])

    def test_no_tip_yet_then_estimate_filled_in(self):
        self.tip.down = True
        self.kupo.add(4900, "t1", make_obj())
        self.assertFalse(self.rd.poll_tip())
        self.assertTrue(self.rd.poll_once())
        b = self.batch(self.rd.state())
        self.assertIsNone(b["depth"])
        self.assertTrue(self.rd.state()["tip_error"])
        self.tip.down = False
        self.rd.poll_tip()
        b = self.batch(self.rd.state())
        self.assertEqual((b["depth"], b["estimate"]), (21, True))

    # ---------------------------------------------------------- identity

    def test_identity_mismatch_and_unknown_signer(self):
        self.poll()
        self.kupo.add(5000, "t1", make_obj(gw="GW02"), owner=ADDR_A)       # says GW02, signed by GW01's wallet
        self.kupo.add(5001, "t2", make_obj(gw="GW01"), owner=ADDR_X)       # signer is not in the table
        self.kupo.add(5002, "t3", make_obj(gw="GW02"), owner=ADDR_B)       # fine
        self.poll()
        b = {x["txid"]: x for x in self.rd.state()["batches"]}
        self.assertEqual(b["t1"]["signer_name"], "GW01")
        self.assertTrue(b["t1"]["warnings"][0].startswith("identity mismatch"))
        self.assertEqual(b["t2"]["warnings"], ["unknown signer"])
        self.assertIsNone(b["t2"]["signer_name"])
        self.assertEqual(b["t3"]["warnings"], [])
        names = [g["name"] for g in self.rd.state()["gateways"]]
        self.assertEqual(names, ["GW01", "GW02", None])                    # the unknown signer is listed too

    # ---------------------------------------------------------- sensors: range, silent, clocks

    def test_out_of_range(self):
        self.kupo.add(4990, "t1", make_obj(groups=[["AGRI_001", 1, 100, [[0, 2450, 1], [1, 7000, 2]]],
                                                    ["AGRI_002", 2, 10, [[0, 1500, 1]]],
                                                    ["AGRI_003", 3, 10, [[0, 500, 1], [1, 400, 2]]]]))
        self.poll()
        s = {x["sensor"]: x for x in self.rd.state()["sensors"]}
        self.assertTrue(s["AGRI_001"]["out_of_range"])             # 70.00 C is above 60
        self.assertEqual(s["AGRI_001"]["out_of_range_count"], 1)
        self.assertEqual(s["AGRI_001"]["points"][-1][2], 1)
        self.assertTrue(s["AGRI_002"]["out_of_range"])             # 150.0 % is above 100
        self.assertFalse(s["AGRI_003"]["out_of_range"])
        rd = self.make(limits=reader.parse_limits("temperature=-10:80"))
        self.poll(rd)
        s = {x["sensor"]: x for x in rd.state()["sensors"]}
        self.assertFalse(s["AGRI_001"]["out_of_range"])

    def test_silent_alarm_uses_the_server_clock(self):
        # the sensor clock is 10 hours behind the server clock: readings look ancient by their own timestamps
        ts = int(self.clock.t) - 36000
        self.poll()
        self.kupo.add(5000, "t1", make_obj(t0=ts))
        self.poll()
        s = self.rd.state()["sensors"][0]
        self.assertFalse(s["silent"])
        self.assertTrue(s["silent_sensor_clock"])                  # shown for information only
        self.assertGreater(s["age_sensor_clock"], 35000)
        self.assertLess(s["seen_age"], 1)
        self.clock.t += 29
        self.assertFalse(self.rd.state()["sensors"][0]["silent"])
        self.clock.t += 2                                          # 31 s without a new reading from the chain
        s = self.rd.state()["sensors"][0]
        self.assertTrue(s["silent"])
        self.assertEqual(s["seen_age"], 31.0)
        # a new batch arrives (readings with an old timestamp again): not silent any more
        self.kupo.add(5010, "t2", make_obj(no=2, t0=ts + 10, groups=[["AGRI_001", 1, 100, [[0, 2400, 9]]]]))
        self.poll()
        self.assertFalse(self.rd.state()["sensors"][0]["silent"])

    def test_sensor_clock_ahead_does_not_hide_a_silent_sensor(self):
        ts = int(self.clock.t) + 36000                             # timestamps in the future
        self.poll()
        self.kupo.add(5000, "t1", make_obj(t0=ts))
        self.poll()
        self.clock.t += 100
        s = self.rd.state()["sensors"][0]
        self.assertTrue(s["silent"])
        self.assertFalse(s["silent_sensor_clock"])

    # ---------------------------------------------------------- Kupo unreachable

    def test_kupo_unreachable_keeps_old_data(self):
        self.kupo.add(4990, "t1", make_obj())
        self.poll()
        self.kupo.down = True
        self.clock.t += 10
        self.assertTrue(self.rd.poll_tip())
        self.assertFalse(self.rd.poll_once())
        self.assertFalse(self.rd.poll_once())
        s = self.rd.state()
        self.assertFalse(s["kupo"]["ok"])
        self.assertIn("refused", s["kupo"]["error"])
        self.assertGreaterEqual(s["kupo"]["last_ok_age"], 10)
        self.assertEqual((s["counts"]["batches"], s["counts"]["readings"]), (1, 2))
        self.assertEqual(len(s["sensors"]), 1)
        self.assertEqual(len([m for m in self.logs if "indexer unreachable" in m]), 1)
        self.kupo.down = False
        self.kupo.add(5000, "t2", make_obj(no=2))
        self.poll()
        s = self.rd.state()
        self.assertTrue(s["kupo"]["ok"])
        self.assertEqual(s["counts"]["batches"], 2)

    def test_kupo_unreachable_at_start(self):
        self.kupo.down = True
        self.assertFalse(self.rd.poll_once())
        s = self.rd.state()
        self.assertFalse(s["kupo"]["ok"])
        self.assertEqual(s["counts"]["batches"], 0)

    def test_node_unreachable_keeps_tip(self):
        self.poll()
        self.tip.down = True
        self.assertFalse(self.rd.poll_tip())
        s = self.rd.state()
        self.assertEqual(s["tip"]["block"], 1000)
        self.assertIn("not reachable", s["tip_error"])

    # ---------------------------------------------------------- rebuild from Kupo

    def test_state_is_rebuilt_from_kupo(self):
        for i in range(5):
            self.kupo.add(4900 + i * 10, "t%d" % i, make_obj(no=i, t0=1000 + i * 10), receipts=i + 1)
        self.poll()
        first = self.rd.state()
        rd2 = self.make()
        self.poll(rd2)
        second = rd2.state()
        self.assertEqual(second["counts"], first["counts"])
        self.assertEqual([b["txid"] for b in second["batches"]], [b["txid"] for b in first["batches"]])
        self.assertEqual(second["sensors"][0]["points"], first["sensors"][0]["points"])


class ServerTest(unittest.TestCase):
    def test_http_endpoints(self):
        kupo, tip, clock = FakeKupo(), FakeTip(), FakeClock()
        kupo.add(4990, "t1", make_obj())
        rd = reader.Reader(kupo, tip, gateways=GATEWAYS, clock=clock, log=lambda m: None)
        rd.poll_tip()
        rd.poll_once()
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(rd, server.os.path.join(server.HERE, "page.html")))
        t = threading.Thread(target=httpd.serve_forever, daemon=True)
        t.start()
        base = "http://127.0.0.1:%d" % httpd.server_address[1]
        try:
            with urllib.request.urlopen(base + "/api/state", timeout=5) as r:
                state = json.loads(r.read().decode())
            self.assertEqual(state["counts"]["batches"], 1)
            self.assertEqual(state["tip"]["block"], 1000)
            with urllib.request.urlopen(base + "/health", timeout=5) as r:
                self.assertTrue(json.loads(r.read().decode())["ok"])
            with urllib.request.urlopen(base + "/", timeout=5) as r:
                page = r.read().decode()
                self.assertIn("text/html", r.headers["Content-Type"])
            self.assertIn("/api/state", page)
            self.assertNotIn("http://", page.replace("http://127", "").replace("http://www.w3.org", ""))   # nothing external
            with self.assertRaises(urllib.error.HTTPError) as cm:
                urllib.request.urlopen(base + "/nothing", timeout=5)
            cm.exception.close()
        finally:
            httpd.shutdown()
            httpd.server_close()


if __name__ == "__main__":
    unittest.main()
