#!/usr/bin/env python3
"""Makes the test batch for Phase 3: 100 readings (10 sensors x 10), the real layout of experiments/pipeline/layout.py,
but under metadata label 9000 so that the page and its reader never take the test traffic for sensor data.
   python3 make_batch.py > batch100.json"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "pipeline"))
import layout

T0 = 1760000000
readings = []
for s in range(10):
    for i in range(10):
        readings.append({"sensor_id": "AGRI_%03d" % (s + 1), "seq": 1000 + i, "ts": T0 + i * 10 + s,
                         "kind": "temperature" if s % 2 == 0 else "humidity",
                         "value": 2400 + s * 13 + i * 3 if s % 2 == 0 else 5500 + s * 7 + i, "scale": 100 if s % 2 == 0 else 10})
clean = [layout.parse_reading(r) for r in readings]
obj = layout.build_batch("BENCH", 1, clean)
obj = {"9000": obj[str(layout.LABEL)]}
data = layout.dump(obj)
sys.stdout.write(data.decode("ascii"))
sys.stderr.write("batch: %d readings, %d bytes of JSON\n" % (len(readings), len(data)))
