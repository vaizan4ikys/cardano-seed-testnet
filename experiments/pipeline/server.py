#!/usr/bin/env python3
"""Web server for the sensor page: one process, three jobs.

  reader thread   asks Kupo for new batches every --poll seconds (reader.py)
  tip thread      asks the node for its tip every --tip-interval seconds (docker exec cardano-cli)
  HTTP server     GET /  the page, GET /api/state  the data as JSON, GET /health  a short status,
                  POST /api/demo  the demo script tells the page which step of the live demo is running

Runs on the chain VM (seedvm). Reads: page.html, gateways.json (name -> wallet address), Kupo over HTTP, the node
tip through `docker exec`. Writes nothing. Environment: KUPO_URL = default of --kupo.

  python3 server.py                          # on seedvm: Kupo at http://10.150.0.71:1442, page on 127.0.0.1:8080
  python3 server.py --port 8088 --kupo http://<pool-1 container ip>:1442
  python3 server.py --help                   # all options with their defaults
  ssh -L 8080:127.0.0.1:8080 seedvm          # on the Mac, then open http://127.0.0.1:8080/

Everything is kept in memory and rebuilt from Kupo at start. Standard library only.
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Type

import reader

HERE = os.path.dirname(os.path.abspath(__file__))     # page.html and gateways.json are looked up here
DEFAULT_KUPO = "http://10.150.0.71:1442"               # Kupo inside pool 1's container (lab address)
DEFAULT_PORT = 8080
REGISTRY_POLL_S = 3.0                                  # seconds between reads of the gateway registry
DEMO_TABS = ("", "sensors", "trust", "details")        # the tabs a demo step may switch the page to
DEMO_STATES = ("running", "done", "finished", "off")   # off = no demo strip on the page
DEMO_MAX_BODY = 4096                                   # bytes: a status is a few short texts


class DemoStatus:
    """What the live demo (experiments/demo/demo.sh) is doing now; the page shows it in a strip under its header.

    demo.sh posts one small JSON object per change; the page reads it back inside /api/state as "demo".
    Kept in memory only: after a restart of the server there is no strip until demo.sh posts again.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._status: dict | None = None

    @staticmethod
    def clean(raw: dict) -> dict:
        """Check a posted status and keep only the known fields (short texts, known tab and state names).

        Raises ValueError when a field has the wrong type or value."""
        def text(key: str, limit: int = 200) -> str:
            value = raw.get(key, "")
            if not isinstance(value, str):
                raise ValueError("%s must be a string" % key)
            return value[:limit]
        step, total = raw.get("step", 0), raw.get("total", 0)
        def whole(x):           # True/False are ints in Python: refuse them
            return isinstance(x, int) and not isinstance(x, bool) and 0 <= x <= 20
        if not (whole(step) and whole(total)):
            raise ValueError("step and total must be whole numbers from 0 to 20")
        steps = raw.get("steps", [])
        if not (isinstance(steps, list) and len(steps) <= 20 and all(isinstance(x, str) for x in steps)):
            raise ValueError("steps must be a list of strings")
        tab, state = text("tab"), text("state") or "running"
        if tab not in DEMO_TABS:
            raise ValueError("tab must be one of %s" % ", ".join(t or '""' for t in DEMO_TABS))
        if state not in DEMO_STATES:
            raise ValueError("state must be one of %s" % ", ".join(DEMO_STATES))
        return {"step": step, "total": total, "steps": [x[:80] for x in steps], "title": text("title"),
                "detail": text("detail", 300), "tab": tab, "state": state}

    def set(self, raw: dict) -> None:
        """Store a new status (checked with clean) together with the time it arrived."""
        status = self.clean(raw)
        status["since"] = time.time()
        with self._lock:
            self._status = status

    def get(self) -> dict | None:
        """The current status with its age in seconds, or None when there is none (or it is "off")."""
        with self._lock:
            status = dict(self._status) if self._status else None
        if not status or status["state"] == "off":
            return None
        status["age"] = round(time.time() - status.pop("since"), 1)
        return status


def make_handler(rd: reader.Reader, page_path: str,
                 demo: DemoStatus | None = None) -> Type[BaseHTTPRequestHandler]:
    """HTTP handler class serving GET / (page), /api/state (JSON for the page), /health (short status)
    and POST /api/demo (the step of the live demo; a new, empty DemoStatus when none is given)."""
    demo = demo or DemoStatus()
    class Handler(BaseHTTPRequestHandler):
        server_version = "sensorpage"

        def _send(self, code, body, ctype):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?")[0]
            if path in ("/", "/index.html"):
                try:
                    with open(page_path, "rb") as f:
                        self._send(200, f.read(), "text/html; charset=utf-8")
                except OSError:
                    self._send(500, b"page.html not found", "text/plain")
            elif path == "/api/state":
                state = rd.state()
                state["demo"] = demo.get()
                self._send(200, json.dumps(state).encode(), "application/json")
            elif path == "/health":
                s = rd.state(max_batches=0)
                body = json.dumps({"ok": True, "kupo_ok": s["kupo"]["ok"],
                                   "tip_block": (s["tip"] or {}).get("block"),
                                   "batches": s["counts"]["batches"]}).encode()
                self._send(200, body, "application/json")
            else:
                self._send(404, b"not found", "text/plain")

        def do_POST(self):
            # only /api/demo; the server listens on 127.0.0.1, so only this machine (or an ssh tunnel) can post
            if self.path.split("?")[0] != "/api/demo":
                self._send(404, b"not found", "text/plain")
                return
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = 0
            if not 0 < length <= DEMO_MAX_BODY:
                self._send(400, b"body missing or too long", "text/plain")
                return
            try:
                demo.set(json.loads(self.rfile.read(length)))
            except (ValueError, TypeError, AttributeError) as err:     # bad JSON or a bad field
                self._send(400, ("bad demo status: %s" % err).encode(), "text/plain")
                return
            self._send(200, b"ok", "text/plain")

        def log_message(self, fmt, *args):      # no line per request
            pass

    return Handler


def main() -> None:
    """Read the options, start the polling threads and the HTTP server, run until Ctrl-C or SIGTERM."""
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1",
                    help="address to listen on (default 127.0.0.1: use an ssh tunnel)")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT, help="port of the page")
    ap.add_argument("--kupo", default=os.environ.get("KUPO_URL", DEFAULT_KUPO),
                    help="URL of Kupo (default: $KUPO_URL, else the lab address)")
    ap.add_argument("--gateways-file", default=os.path.join(HERE, "gateways.json"),
                    help="name -> wallet address (json)")
    ap.add_argument("--final-depth", type=int, default=60, help="blocks after which a batch is final (k)")
    ap.add_argument("--window", type=int, default=300, help="slots read again on every poll (rollback check)")
    ap.add_argument("--poll", type=float, default=2.0, help="seconds between Kupo polls")
    ap.add_argument("--tip-interval", type=float, default=2.0, help="seconds between node tip queries")
    ap.add_argument("--silent-after", type=float, default=90.0,
                    help="seconds without a new reading arriving from the chain (server clock) = silent; keep it "
                         "above the gateway batch time T")
    ap.add_argument("--limits", default="", help="out-of-range limits, e.g. temperature=-40:60,humidity=0:100")
    ap.add_argument("--container", default=None, help="pool 1 container name (default: found with docker ps)")
    ap.add_argument("--magic", type=int, default=42, help="network magic of the testnet (net 1 = 42)")
    ap.add_argument("--receipt-policy", default=None, help="policy id of the RECEIPT token (default: any policy)")
    ap.add_argument("--registry-dir", default="/tmp/p0n",
                    help="directory in pool 1's container with admin.addr, policy.id, token.hex (the registry coin "
                         "is read through Kupo so the page can show who is approved); "
                         "'none' = do not read the registry")
    ap.add_argument("--page", default=os.path.join(HERE, "page.html"))
    a = ap.parse_args()
    if a.poll < 1 or a.tip_interval < 1:
        ap.error("--poll and --tip-interval must be at least 1 second")

    gateways = reader.load_gateways(a.gateways_file)
    kc = reader.KupoClient(a.kupo)
    registry = None if a.registry_dir == "none" else reader.Registry(kc, a.registry_dir, a.container)
    rd = reader.Reader(kc, reader.DockerTip(a.container, a.magic), gateways=gateways, registry=registry,
                       final_depth=a.final_depth, window=a.window, silent_after=a.silent_after,
                       limits=reader.parse_limits(a.limits), receipt_policy=a.receipt_policy, kupo_url=a.kupo)
    print("gateways: %s" % (", ".join(sorted(gateways)) or "none (file %s)" % a.gateways_file), flush=True)
    stop = threading.Event()
    rd.poll_tip()           # first tip before the first Kupo round, so old batches get a depth estimate at once

    def loop_thread(fn, interval):
        return threading.Thread(target=reader.run_loop, args=(fn, interval, stop), daemon=True)
    threads = [loop_thread(rd.poll_once, a.poll)]
    if registry:
        threads.append(loop_thread(registry.poll, REGISTRY_POLL_S))
    threads.append(loop_thread(rd.poll_tip, a.tip_interval))
    for t in threads:
        t.start()
    httpd = ThreadingHTTPServer((a.host, a.port), make_handler(rd, a.page, DemoStatus()))
    httpd.daemon_threads = True

    def shutdown(signum, frame):        # httpd.shutdown() blocks, so it runs in its own thread
        stop.set()
        threading.Thread(target=httpd.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    print("page on http://%s:%d/   Kupo %s" % (a.host, a.port, a.kupo), flush=True)
    httpd.serve_forever()
    httpd.server_close()
    stop.set()


if __name__ == "__main__":
    main()
