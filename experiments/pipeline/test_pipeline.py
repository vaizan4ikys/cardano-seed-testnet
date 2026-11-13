"""Tests for the sensor -> gateway pipeline.  Run:  python3 -m unittest -v test_pipeline  (in this folder)"""
import hashlib
import json
import os
import random
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

import calc_size
import gateway
import layout
import sensor

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_B = 100


def reading(sensor_id="AGRI_001", seq=1, ts=1760000000, kind="temperature", value=2450, scale=100):
    return {"sensor_id": sensor_id, "seq": seq, "ts": ts, "kind": kind, "value": value, "scale": scale}


def slurp(path, mode="rb"):
    with open(path, mode) as f:
        return f.read()


def quiet(msg):
    pass


class FakeClock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


class TmpDirCase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="pipeline-test-")
        self.addCleanup(shutil.rmtree, self.dir, True)

    def batches(self):
        return sorted(f for f in os.listdir(self.dir) if f.startswith("batch-") and f.endswith(".json"))


class TestLayout(unittest.TestCase):
    def test_default_batch_limits(self):
        obj = calc_size.new_size(DEFAULT_B)[2]
        layout.check_metadata(obj)                       # no floats, no string > 64 bytes
        self.assertLess(layout.tx_estimate(obj), layout.MAX_TX)
        data = layout.dump(obj)
        self.assertNotIn(b".", data)                     # no decimal numbers in the JSON text
        self.assertTrue(all(isinstance(x, (int, str, list)) for x in [obj["1000"]]))

    def test_check_rejects_bad_values(self):
        for bad in ({"1000": [1.5]}, {"1000": ["x" * 65]}, {"1000": [True]}, {"1000": [None]}):
            with self.assertRaises(ValueError):
                layout.check_metadata(bad)
        layout.check_metadata({"1000": ["x" * 64, -5, 7]})

    def test_cbor_len(self):
        self.assertEqual(layout.cbor_len(23), 1)
        self.assertEqual(layout.cbor_len(24), 2)
        self.assertEqual(layout.cbor_len(-24), 1)
        self.assertEqual(layout.cbor_len(-25), 2)
        self.assertEqual(layout.cbor_len(2450), 3)
        self.assertEqual(layout.cbor_len(1760000000), 5)
        self.assertEqual(layout.cbor_len("AGRI"), 5)
        self.assertEqual(layout.cbor_len([1, 2, 3]), 4)

    def test_roundtrip(self):
        rs = [reading(seq=i, ts=1760000000 + i, value=2000 + i) for i in range(1, 6)]
        rs.append(reading("AGRI_002", 1, 1760000003, "humidity", 625, 10))
        back = layout.decode_batch(layout.build_batch("GW01", 1, rs))
        self.assertEqual(len(back), 6)
        self.assertEqual(sorted(b["ts"] for b in back), sorted(r["ts"] for r in rs))
        self.assertEqual({b["sensor"] for b in back}, {"AGRI_001", "AGRI_002"})

    def test_parse_reading(self):
        layout.parse_reading(reading())
        for bad in (reading(value=24.5), reading(kind="wind"), reading(seq=True), reading(scale=0),
                    reading(sensor_id="x" * 65), "text"):
            with self.assertRaises(ValueError):
                layout.parse_reading(bad)

    def test_ids(self):
        for ok in ("AGRI_001", "ATMO_001", "a.b-c_9", "x" * 32, "GW01"):
            self.assertTrue(layout.valid_id(ok), ok)
        for bad in ("", "x" * 33, "0xAB", "0XAB", "0x", "a b", "a/b", "\u00e4", "A\n", None, 5):
            self.assertFalse(layout.valid_id(bad), bad)
        self.assertTrue(layout.valid_id("x0xAB"))
        with self.assertRaises(ValueError):
            layout.parse_reading(reading(sensor_id="0xdead"))

    def test_full_sensor_id_in_batch(self):
        obj = layout.build_batch("GW01", 1, [reading("AGRI_001"), reading("ATMO_001")])
        self.assertEqual([g[0] for g in obj["1000"][4]], ["AGRI_001", "ATMO_001"])   # no clash

    def test_integer_ranges(self):
        for bad in (reading(value=2 ** 53 + 1), reading(value=-2 ** 64 - 1), reading(value=2 ** 64),
                    reading(seq=-1), reading(seq=2 ** 32), reading(ts=-1), reading(ts=2 ** 40),
                    reading(scale=-5), reading(scale=10 ** 6 + 1), reading(value=True),
                    reading(ts=False), reading(scale=True), reading(seq=1.0)):
            with self.assertRaises(ValueError, msg=bad):
                layout.parse_reading(bad)
        layout.parse_reading(reading(value=-2 ** 53, seq=0, ts=0, scale=1))
        layout.parse_reading(reading(value=2 ** 53, seq=2 ** 32 - 1, ts=2 ** 40 - 1, scale=10 ** 6))
        for bad in (2 ** 64, -2 ** 64 - 1):
            with self.assertRaises(ValueError):
                layout.check_metadata({"1000": [bad]})
        layout.check_metadata({"1000": [2 ** 64 - 1, -2 ** 64]})

    def test_capacity_with_default_reserve(self):
        self.assertEqual(layout.TX_RESERVE, 1500)
        def parts(n):
            return len(layout.fit_chunks(calc_size.make_readings(n), "GW01"))
        self.assertEqual(parts(1800), 1)
        self.assertGreater(parts(2000), 1)
        self.assertGreater(len(layout.fit_chunks(calc_size.make_readings(1000), "GW01", 15000)), 1)
        obj = calc_size.new_size(DEFAULT_B)[2]
        self.assertLess(layout.tx_estimate(obj, layout.CONTRACT_OVERHEAD), 2300)   # contract tx, B=100

    def test_huge_batch_is_split(self):
        rs = [reading("AGRI_%03d" % (i % 50), i, 1760000000 + i, value=i * 7919) for i in range(4000)]
        chunks = layout.fit_chunks(rs, "GW01")
        self.assertGreater(len(chunks), 1)
        self.assertEqual(sum(len(c) for c in chunks), 4000)
        for c in chunks:
            self.assertTrue(layout.fits(layout.build_batch("GW01", 0, c)))

    def test_hash_rule(self):
        data = layout.dump(layout.build_batch("GW01", 3, [reading()]))
        self.assertEqual(layout.batch_hash(data), hashlib.sha256(data).hexdigest())
        self.assertEqual(len(layout.batch_hash(data)), 64)       # 32 bytes in hex
        self.assertFalse(data.endswith(b"\n"))


class TestSensor(unittest.TestCase):
    def test_walk_is_bounded_and_integer(self):
        s = sensor.SimSensor("AGRI_001", "temperature", random.Random(1), outlier_pct=0)
        lo, hi, scale = sensor.RANGES["temperature"]
        seqs = []
        for i in range(2000):
            r = s.reading(1760000000 + i)
            self.assertIsInstance(r["value"], int)
            self.assertTrue(lo * scale <= r["value"] <= hi * scale)
            seqs.append(r["seq"])
        self.assertEqual(seqs, list(range(1, 2001)))

    def test_outliers(self):
        s = sensor.SimSensor("AGRI_001", "humidity", random.Random(2), outlier_pct=10)
        lo, hi, scale = sensor.RANGES["humidity"]
        out = sum(1 for i in range(2000)
                  if not lo * scale <= s.reading(i)["value"] <= hi * scale)
        self.assertTrue(100 < out < 300, out)

    def test_readings_pass_the_gateway_check(self):
        s = sensor.SimSensor("AGRI_001", "soil_moisture", random.Random(3), 5)
        layout.parse_reading(json.loads(json.dumps(s.reading(1760000000))))


class TestGateway(TmpDirCase):
    def make(self, B=3, T=10, submit=None, clock=None, log=quiet, **kw):
        return gateway.Gateway(self.dir, B, T, submit or gateway.make_submit("dry"),
                               clock=clock or FakeClock(), log=log, **kw)

    def test_dedup(self):
        gw = self.make(B=100)
        self.assertEqual(gw.add_reading(reading(seq=1)), "ok")
        self.assertEqual(gw.add_reading(reading(seq=1)), "dup")
        self.assertEqual(gw.add_reading(reading("AGRI_002", seq=1)), "ok")   # other sensor, same seq
        self.assertEqual(gw.add_reading(reading(seq=2)), "ok")
        self.assertEqual(gw.add_reading(reading(value=1.5, seq=3)), "bad")
        self.assertEqual(len(gw.buf), 3)
        self.assertEqual((gw.stats["dup"], gw.stats["bad"]), (1, 1))

    def test_dedup_survives_restart(self):
        gw = self.make(B=2)
        gw.add_reading(reading(seq=1))
        gw.add_reading(reading(seq=2))                    # batch written, state saved
        gw2 = self.make(B=2)
        self.assertEqual(gw2.add_reading(reading(seq=2)), "dup")
        self.assertEqual(gw2.add_reading(reading(seq=3)), "ok")

    def test_batch_by_B(self):
        gw = self.make(B=3)
        for i in range(1, 8):
            gw.add_reading(reading(seq=i))
        self.assertEqual(len(self.batches()), 2)          # 6 readings out, 1 waiting
        self.assertEqual(len(gw.buf), 1)
        data = slurp(os.path.join(self.dir, self.batches()[0]))
        self.assertEqual(len(layout.decode_batch(json.loads(data))), 3)

    def test_batch_by_T(self):
        clock = FakeClock()
        gw = self.make(B=100, T=10, clock=clock)
        gw.add_reading(reading(seq=1))
        clock.t += 9
        gw.add_reading(reading(seq=2))
        gw.tick()
        self.assertEqual(self.batches(), [])              # oldest has waited 9 s only
        clock.t += 1
        gw.tick()
        self.assertEqual(len(self.batches()), 1)
        self.assertEqual(gw.buf, [])
        data = slurp(os.path.join(self.dir, self.batches()[0]))
        self.assertEqual(len(layout.decode_batch(json.loads(data))), 2)

    def test_file_name_and_hash(self):
        gw = self.make(B=2)
        gw.add_reading(reading(seq=1))
        gw.add_reading(reading(seq=2))
        name = self.batches()[0]
        data = slurp(os.path.join(self.dir, name))
        self.assertEqual(name, "batch-000001-%s.json" % hashlib.sha256(data).hexdigest())

    def test_restart_resends_pending(self):
        calls = []
        gw = self.make(B=2, submit=lambda p, h: False)    # submit always fails
        for i in (1, 2, 3, 4):
            gw.add_reading(reading(seq=i))
        gw.send_pending()
        self.assertEqual(len(self.batches()), 2)
        self.assertEqual(len(gw.pending_files()), 2)
        before = {n: slurp(os.path.join(self.dir, n)) for n in self.batches()}

        def ok(path, h):
            calls.append((os.path.basename(path), h))
            return True
        gw2 = self.make(B=2, submit=ok)                   # "restart"
        self.assertTrue(gw2.send_pending())
        self.assertEqual([c[0] for c in calls], self.batches())          # oldest first
        for name, h in calls:
            self.assertIn(h, name)
            self.assertEqual(slurp(os.path.join(self.dir, name)), before[name])  # same file
        self.assertEqual(gw2.pending_files(), [])
        gw2.send_pending()
        self.assertEqual(len(calls), 2)                   # sent ones are not sent again
        gw2.add_reading(reading(seq=5))
        gw2.add_reading(reading(seq=6))
        self.assertIn("batch-000003-", self.batches()[-1])  # counter goes on

    def test_missing_status_counts_as_pending(self):
        gw = self.make(B=1, submit=lambda p, h: False)
        gw.add_reading(reading(seq=1))
        os.remove(os.path.join(self.dir, self.batches()[0] + ".status"))
        self.assertEqual(len(gw.pending_files()), 1)

    def test_command_mode(self):
        out = os.path.join(self.dir, "calls.txt")
        script = os.path.join(self.dir, "submit.sh")
        with open(script, "w") as f:
            f.write('#!/bin/sh\necho "$1 $2" >> "%s"\n' % out)
        os.chmod(script, 0o755)
        gw = self.make(B=1, submit=gateway.make_submit("command", script + " {file} {hash}", quiet))
        gw.add_reading(reading(seq=1))
        self.assertTrue(gw.send_pending())
        path, h = slurp(out, "r").split()
        self.assertTrue(path.endswith(".json"))
        self.assertEqual(h, hashlib.sha256(slurp(path)).hexdigest())
        # failing command leaves the batch pending
        gw2 = self.make(B=1, submit=gateway.make_submit("command", "false", quiet))
        gw2.add_reading(reading(seq=2))
        self.assertFalse(gw2.send_pending())
        self.assertEqual(len(gw2.pending_files()), 1)


class TestGatewayRobustness(TmpDirCase):
    def make(self, B=3, T=10, submit=None, log=quiet, **kw):
        return gateway.Gateway(self.dir, B, T, submit or gateway.make_submit("dry", log=log),
                               clock=FakeClock(), log=log, **kw)

    def test_bad_ids_and_numbers_never_reach_a_batch(self):
        logs = []
        gw = self.make(B=2, log=logs.append)
        bads = [reading("0xBEEF", 1), reading("0xBEEF", 2), reading("bad id", 1), reading("A" * 40, 1),
                reading(value=2 ** 70), reading(seq=-3), reading(scale=0), reading(value=True)]
        for b in bads:
            self.assertEqual(gw.add_reading(b), "bad")
        gw.add_reading(reading(seq=1))
        gw.add_reading(reading(seq=2))
        self.assertEqual(gw.stats["bad"], len(bads))
        self.assertEqual(len(gw.buf), 0)
        names = [n for n in os.listdir(self.dir) if n.endswith(".json") and n.startswith("batch-")]
        self.assertEqual(len(names), 1)
        text = slurp(os.path.join(self.dir, names[0]), "r")
        self.assertNotIn("0xBEEF", text)
        self.assertEqual(len(layout.decode_batch(json.loads(text))), 2)
        rejected = [m for m in logs if m.startswith("rejected")]
        self.assertEqual(sum("0xBEEF" in m for m in rejected), 1)    # logged once per sensor
        self.assertEqual(len(rejected), 4)   # sensors 0xBEEF, "bad id", AAAA.., and AGRI_001 (first bad one)

    def test_gateway_id_checked(self):
        for bad in ("0xGW", "", "g w", "x" * 33):
            with self.assertRaises(ValueError):
                self.make(gateway_id=bad)

    def test_tx_reserve_option_splits_batches(self):
        gw = self.make(B=200, tx_reserve=15000)
        for i in range(200):
            gw.add_reading(reading("AGRI_%03d" % (i % 10), i // 10 + 1000, 1760000000 + i, value=2000 + i))
        files = [n for n in os.listdir(self.dir) if n.startswith("batch-") and n.endswith(".json")]
        self.assertGreater(len(files), 1)
        total = sum(len(layout.decode_batch(json.loads(slurp(os.path.join(self.dir, n))))) for n in files)
        self.assertEqual(total, 200)

    def test_dead_letter(self):
        logs = []
        calls = []
        gw = self.make(B=1, max_tries=3, log=logs.append,
                       submit=lambda p, h: calls.append(os.path.basename(p)) or "batch-000001-" not in p)
        gw.add_reading(reading(seq=1))
        gw.add_reading(reading(seq=2))
        self.assertFalse(gw.send_pending())               # batch 1 fails (try 1), batch 2 waits: order kept
        self.assertEqual(len(calls), 1)
        gw2 = self.make(B=1, max_tries=3, log=logs.append,        # restart: tries are remembered
                        submit=lambda p, h: calls.append(os.path.basename(p)) or "batch-000001-" not in p)
        self.assertFalse(gw2.send_pending())              # try 2
        self.assertTrue(gw2.send_pending())               # try 3: dead letter, batch 2 goes on
        dead = os.listdir(os.path.join(self.dir, "dead"))
        self.assertEqual(sorted(d[:12] for d in dead), ["batch-000001", "batch-000001"])
        self.assertEqual(gw2.pending_files(), [])
        self.assertEqual([n[:12] for n in self.batches()], ["batch-000002"])
        self.assertEqual(gw2.stats["dead"], 1)
        self.assertTrue(any("DEAD LETTER" in m for m in logs))
        gw2.send_pending()
        self.assertEqual(len(calls), 4)                   # dead batch is not tried again
        gw3 = self.make(B=1)
        gw3.add_reading(reading(seq=9))
        self.assertIn("batch-000003-", self.batches()[-1])    # counter does not reuse numbers

    def test_refused_goes_to_dead_at_once(self):
        logs, calls = [], []
        gw = self.make(B=1, max_tries=5, log=logs.append,
                       submit=lambda p, h: calls.append(os.path.basename(p)) or
                       ("refused" if "batch-000001-" in p else True))
        gw.add_reading(reading(seq=1))
        gw.add_reading(reading(seq=2))
        self.assertTrue(gw.send_pending())                # batch 1 refused: dead at once, batch 2 is sent
        self.assertEqual(len(calls), 2)
        self.assertEqual(gw.stats["dead"], 1)
        self.assertTrue(any("DEAD LETTER" in m and "was refused" in m for m in logs))
        gw.send_pending()
        self.assertEqual(len(calls), 2)                   # never tried again

    def test_command_exit_code_2_means_refused(self):
        logs = []
        sub = gateway.make_submit("command", "sh -c 'echo contract says no; exit 2' x", log=logs.append)
        path = os.path.join(self.dir, "x.json")
        open(path, "wb").write(b"{}")
        self.assertEqual(sub(path, "h"), "refused")
        self.assertTrue(any("REFUSED" in m and "contract says no" in m for m in logs))
        sub1 = gateway.make_submit("command", "sh -c 'exit 1' x", log=logs.append)
        self.assertFalse(sub1(path, "h"))
        sub0 = gateway.make_submit("command", "sh -c 'exit 0' x", log=logs.append)
        self.assertTrue(sub0(path, "h"))

    def test_restart_warning_once(self):
        logs = []
        gw = self.make(B=100, log=logs.append)
        gw.add_reading(reading(seq=5000))
        for q in (1, 2, 3):
            gw.add_reading(reading(seq=q))                # far below: warn once
        gw.add_reading(reading("AGRI_002", seq=1))        # other sensor, no warning
        w = [m for m in logs if "sensor restarted?" in m]
        self.assertEqual(len(w), 1)
        self.assertIn("AGRI_001", w[0])
        gw.add_reading(reading(seq=4500))                 # only 500 below: no warning, no new log
        self.assertEqual(len([m for m in logs if "sensor restarted?" in m]), 1)

    def test_parallel_receiving(self):
        import threading
        gw = self.make(B=10)
        def work(k):
            for i in range(500):
                gw.add_reading(reading("S%d" % k, i + 1, 1760000000 + i))
                if i % 50 == 0:
                    gw.count_bad()
                    gw.add_reading(reading("S%d" % k, i + 1, 1760000000 + i))   # duplicate
        ts = [threading.Thread(target=work, args=(k,)) for k in range(8)]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        gw.flush_now()
        self.assertEqual(gw.stats["received"], 4000)
        self.assertEqual(gw.stats["dup"], 80)
        self.assertEqual(gw.stats["bad"], 80)
        seen = set()
        for n in self.batches():
            for r in layout.decode_batch(json.loads(slurp(os.path.join(self.dir, n)))):
                seen.add((r["sensor"], r["seq"]))
        self.assertEqual(len(seen), 4000)
        self.assertEqual(len(self.batches()), 400)

    def test_readings_after_shutdown_are_refused(self):
        gw = self.make(B=100)
        gw.add_reading(reading(seq=1))
        gw.shutdown()
        self.assertEqual(len(self.batches()), 1)          # the waiting reading was written out
        self.assertEqual(gw.add_reading(reading(seq=2)), "closed")
        self.assertEqual(gw.stats["late"], 1)
        self.assertEqual(gw.pending_files(), [])          # dry submit marked it sent

    def test_flush_failure_keeps_readings(self):
        gw = self.make(B=2)
        gw.add_reading(reading(seq=1))
        real = gateway.write_atomic
        def broken(path, data):
            raise OSError("disk full")
        gateway.write_atomic = broken
        try:
            gw.add_reading(reading(seq=2))
        finally:
            gateway.write_atomic = real
        self.assertEqual(len(gw.buf), 2)
        self.assertEqual(self.batches(), [])
        gw.tick(now=gw.clock() + 100)                     # later the disk works again
        self.assertEqual(len(self.batches()), 1)
        self.assertEqual(gw.buf, [])


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class TestEndToEnd(TmpDirCase):
    def test_sensor_to_gateway_dry_run(self):
        port = free_port()
        out = os.path.join(self.dir, "outbox")
        gw = subprocess.Popen([sys.executable, os.path.join(HERE, "gateway.py"), "--B", "15", "--T", "2",
                               "--listen-port", str(port), "--outbox", out, "--submit", "dry"],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            for _ in range(50):                           # wait until it listens
                try:
                    socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                    break
                except OSError:
                    time.sleep(0.1)
            sn = subprocess.run([sys.executable, os.path.join(HERE, "sensor.py"), "--sensors", "4",
                                 "--interval", "0.4", "--duration", "4", "--port", str(port),
                                 "--silent-sensor", "AGRI_004", "--silent-after", "2", "--seed", "5"],
                                capture_output=True, text=True, timeout=30)
            self.assertEqual(sn.returncode, 0, sn.stderr)
            sent = int(sn.stderr.split("sent ")[1].split()[0])
            time.sleep(0.5)
        finally:
            gw.send_signal(signal.SIGTERM)
            log = gw.communicate(timeout=15)[0]
        files = sorted(f for f in os.listdir(out) if f.startswith("batch-") and f.endswith(".json"))
        self.assertGreaterEqual(len(files), 2, log)
        total, seen = 0, set()
        for f in files:
            data = slurp(os.path.join(out, f))
            self.assertIn(hashlib.sha256(data).hexdigest(), f)
            self.assertEqual(slurp(os.path.join(out, f + ".status"), "r"), "sent")
            obj = json.loads(data)
            layout.check_metadata(obj)
            for r in layout.decode_batch(obj):
                total += 1
                seen.add((r["sensor"], r["seq"]))
        self.assertEqual(total, sent, log)
        self.assertEqual(len(seen), total)                # no duplicates
        self.assertIn("wait of oldest", log)
        silent = [s for s, _ in seen if s == "AGRI_004"]
        self.assertTrue(len(silent) < total / 4)          # the silent sensor sent less than its share


if __name__ == "__main__":
    unittest.main()
