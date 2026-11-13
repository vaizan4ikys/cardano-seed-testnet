"""Tests for kupo_reader.py without a chain: Kupo's answer format is simulated."""
import unittest

import kupo_reader
import layout


def to_schema(x):
    """The shape Kupo uses for metadata (the inverse of schema_to_plain, for lists, ints and strings)."""
    if isinstance(x, bool):
        raise TypeError
    if isinstance(x, int):
        return {"int": x}
    if isinstance(x, str):
        return {"string": x}
    return {"list": [to_schema(i) for i in x]}


class KupoReaderTest(unittest.TestCase):
    def test_batch_round_trip_keeps_hash(self):
        obj = {"1000": [1, "GW01", 7, 1794493633,
                        [["AGRI_001", 1, 100, [[0, 2135, 1], [1, 2109, 2], [3, -5, 3]]],
                         ["AGRI_002", 2, 10, [[0, 709, 1]]]]]}
        want = layout.batch_hash(layout.dump(obj))
        item = {"hash": "00", "raw": "00", "schema": {"1000": to_schema(obj["1000"])}}
        got, h = kupo_reader.batch_from_metadata(item)
        self.assertEqual(got, obj)
        self.assertEqual(h, want)

    def test_real_kupo_answer_with_a_map(self):
        # taken from a real Kupo answer on the private chain (older test transaction, map layout)
        item = {"hash": "0ebe7115132eef79b8fa8df447012bde49b9b0773153332d5c598e183648c4cc", "raw": "d9",
                "schema": {"1000": {"map": [
                    {"k": {"string": "t"}, "v": {"string": "2026-11-12T04:19:24Z"}},
                    {"k": {"string": "temp"}, "v": {"int": 2450}},
                    {"k": {"string": "scale"}, "v": {"int": 100}},
                    {"k": {"string": "sensor"}, "v": {"string": "AGRI_001"}}]}}}
        obj, _ = kupo_reader.batch_from_metadata(item)
        self.assertEqual(obj["1000"], {"t": "2026-11-12T04:19:24Z", "temp": 2450, "scale": 100, "sensor": "AGRI_001"})

    def test_other_label_is_ignored(self):
        self.assertEqual(kupo_reader.batch_from_metadata({"schema": {"674": {"int": 1}}}), (None, None))

    def test_bytes_and_unknown_types(self):
        self.assertEqual(kupo_reader.schema_to_plain({"bytes": "ab"}), "0xab")
        with self.assertRaises(ValueError):
            kupo_reader.schema_to_plain({"float": 1.5})

    def test_new_transactions_keeps_order_and_drops_repeats(self):
        k = kupo_reader.Kupo()
        k._get = lambda path, **p: ([
            {"transaction_id": "aa", "created_at": {"slot_no": 10}},
            {"transaction_id": "aa", "created_at": {"slot_no": 10}},   # second output of the same transaction
            {"transaction_id": "bb", "created_at": {"slot_no": 12}}], {})
        self.assertEqual(k.new_transactions(5), [(10, "aa"), (12, "bb")])

    def test_batch_returns_header_hash(self):
        k = kupo_reader.Kupo()
        obj = {"1000": [1, "GW01", 1, 5, [["S1", 1, 100, [[0, 1, 1]]]]]}
        k._get = lambda path, **p: ([{"schema": {"1000": to_schema(obj["1000"])}}], {"X-Block-Header-Hash": "ff"})
        got, h, header = k.batch(10, "aa")
        self.assertEqual((got, header), (obj, "ff"))
        self.assertEqual(h, layout.batch_hash(layout.dump(obj)))


if __name__ == "__main__":
    unittest.main()
