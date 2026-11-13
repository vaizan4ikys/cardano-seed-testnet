#!/usr/bin/env python3
"""Web server for the sensor page: one process, three jobs.

  reader thread   asks Kupo for new batches every --poll seconds (reader.py)
  tip thread      asks the node for its tip every --tip-interval seconds (docker exec cardano-cli)
  HTTP server     GET /  the page, GET /api/state  the data as JSON, GET /health  a short status

  python3 server.py                          # on seedvm: Kupo at http://10.150.0.71:1442, page on 127.0.0.1:8080
  ssh -L 8080:127.0.0.1:8080 seedvm          # on the Mac, then open http://127.0.0.1:8080/

Everything is kept in memory and rebuilt from Kupo at start. Standard library only.
"""
import argparse
import json
import os
import signal
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import reader

HERE = os.path.dirname(os.path.abspath(__file__))


def make_handler(rd, page_path):
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
                body = json.dumps(rd.state()).encode()
                self._send(200, body, "application/json")
            elif path == "/health":
                s = rd.state(max_batches=0)
                body = json.dumps({"ok": True, "kupo_ok": s["kupo"]["ok"], "tip_block": (s["tip"] or {}).get("block"),
                                   "batches": s["counts"]["batches"]}).encode()
                self._send(200, body, "application/json")
            else:
                self._send(404, b"not found", "text/plain")

        def log_message(self, fmt, *args):      # no line per request
            pass

    return Handler


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1", help="address to listen on (default 127.0.0.1: use an ssh tunnel)")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--kupo", default=os.environ.get("KUPO_URL", "http://10.150.0.71:1442"))
    ap.add_argument("--gateways-file", default=os.path.join(HERE, "gateways.json"), help="name -> wallet address (json)")
    ap.add_argument("--final-depth", type=int, default=60, help="blocks after which a batch is final (k)")
    ap.add_argument("--window", type=int, default=300, help="slots read again on every poll (rollback check)")
    ap.add_argument("--poll", type=float, default=2.0, help="seconds between Kupo polls")
    ap.add_argument("--tip-interval", type=float, default=2.0, help="seconds between node tip queries")
    ap.add_argument("--silent-after", type=float, default=90.0,
                    help="seconds without a new reading arriving from the chain (server clock) = silent; keep it "
                         "above the gateway batch time T")
    ap.add_argument("--limits", default="", help="out-of-range limits, e.g. temperature=-40:60,humidity=0:100")
    ap.add_argument("--container", default=None, help="pool 1 container name (default: found with docker ps)")
    ap.add_argument("--magic", type=int, default=42)
    ap.add_argument("--receipt-policy", default=None, help="policy id of the RECEIPT token (default: any policy)")
    ap.add_argument("--page", default=os.path.join(HERE, "page.html"))
    a = ap.parse_args()
    if a.poll < 1 or a.tip_interval < 1:
        ap.error("--poll and --tip-interval must be at least 1 second")

    gateways = reader.load_gateways(a.gateways_file)
    rd = reader.Reader(reader.KupoClient(a.kupo), reader.DockerTip(a.container, a.magic), gateways=gateways,
                       final_depth=a.final_depth, window=a.window, silent_after=a.silent_after,
                       limits=reader.parse_limits(a.limits), receipt_policy=a.receipt_policy, kupo_url=a.kupo)
    print("gateways: %s" % (", ".join(sorted(gateways)) or "none (file %s)" % a.gateways_file), flush=True)
    stop = threading.Event()
    rd.poll_tip()           # first tip before the first Kupo round, so old batches get a depth estimate at once
    threads = [threading.Thread(target=reader.run_loop, args=(rd.poll_once, a.poll, stop), daemon=True),
               threading.Thread(target=reader.run_loop, args=(rd.poll_tip, a.tip_interval, stop), daemon=True)]
    for t in threads:
        t.start()
    httpd = ThreadingHTTPServer((a.host, a.port), make_handler(rd, a.page))
    httpd.daemon_threads = True

    def shutdown(signum, frame):
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
