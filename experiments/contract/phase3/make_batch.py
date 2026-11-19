#!/usr/bin/env python3
"""Makes the test batch for Phase 3: 100 readings (10 sensors x 10), the real layout of experiments/pipeline/layout.py,
but under metadata label 9000 so that the page and its reader never take the test traffic for sensor data.

Run:    python3 make_batch.py > batch100.json
Reads:  the module layout.py of experiments/pipeline (found relative to this file).
Writes: the batch as JSON on stdout; a one-line summary ("batch: N readings, M bytes of JSON") on stderr.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "pipeline"))
import layout  # noqa: E402  (needs the path above)

T0 = 1760000000          # time of the first reading (epoch seconds)
SENSORS = 10             # sensors AGRI_001 .. AGRI_010
READINGS_PER_SENSOR = 10
TEST_LABEL = "9000"      # metadata label of the test traffic (the page ignores it)


def make_readings() -> list:
    """The raw readings: even sensors send temperature (scale 100), odd sensors humidity (scale 10)."""
    readings = []
    for s in range(SENSORS):
        for i in range(READINGS_PER_SENSOR):
            temperature = s % 2 == 0
            readings.append({
                "sensor_id": "AGRI_%03d" % (s + 1),
                "seq": 1000 + i,
                "ts": T0 + i * 10 + s,
                "kind": "temperature" if temperature else "humidity",
                "value": 2400 + s * 13 + i * 3 if temperature else 5500 + s * 7 + i,
                "scale": 100 if temperature else 10,
            })
    return readings


def main() -> None:
    readings = make_readings()
    clean = [layout.parse_reading(r) for r in readings]
    batch = layout.build_batch("BENCH", 1, clean)
    batch = {TEST_LABEL: batch[str(layout.LABEL)]}       # same content, other metadata label
    data = layout.dump(batch)
    sys.stdout.write(data.decode("ascii"))
    sys.stderr.write("batch: %d readings, %d bytes of JSON\n" % (len(readings), len(data)))


if __name__ == "__main__":
    main()
