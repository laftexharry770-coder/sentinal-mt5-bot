#!/usr/bin/env python3
"""
Sentinal Copier relay.

Lets a master on one machine feed slaves on other machines. The master POSTs
its snapshot, slaves GET it. The relay holds the latest snapshot per channel
in memory and nothing else - no history, no database, no trading logic. It
never sees an account password and cannot place a trade.

Run it on any box the terminals can reach:

    python3 copier_relay.py --key CHANGE-ME --port 8787

Behind a reverse proxy with TLS (recommended, and required if you want the
key to stay private in transit):

    location / { proxy_pass http://127.0.0.1:8787; }

Endpoints
    POST /publish?channel=NAME     body = snapshot     master -> relay
    GET  /feed?channel=NAME        body = snapshot     relay  -> slave
    GET  /health                                       liveness check

Both require the header  X-Copier-Key: <shared secret>.
"""

import argparse
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

MAX_BODY = 1_048_576          # 1 MB is far more than any real snapshot
STALE_AFTER = 300             # forget a channel nobody has published to in 5 min

_lock = threading.Lock()
_channels = {}                # name -> (payload bytes, monotonic timestamp)
_key = ""


def _prune(now):
    """Drop channels whose master stopped publishing long ago."""
    for name in [n for n, (_, ts) in _channels.items() if now - ts > STALE_AFTER]:
        del _channels[name]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "SentinalCopierRelay/1.0"

    # --- helpers -----------------------------------------------------
    def _send(self, code, body=b"", ctype="text/plain; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _authorised(self):
        # Constant-ish time compare; the secret is short and the endpoint is
        # not a high-value target, but there is no reason to leak length.
        supplied = self.headers.get("X-Copier-Key", "")
        if len(supplied) != len(_key):
            return False
        return sum(a != b for a, b in zip(supplied, _key)) == 0

    def _channel(self):
        q = parse_qs(urlparse(self.path).query)
        name = (q.get("channel") or [""])[0].strip()
        # Channel names end up as dict keys only, but keep them boring.
        if not name or len(name) > 64 or not all(
            c.isalnum() or c in "-_" for c in name
        ):
            return None
        return name

    # --- routes ------------------------------------------------------
    def do_GET(self):
        route = urlparse(self.path).path

        if route == "/health":
            with _lock:
                n = len(_channels)
            self._send(200, f"ok {n} channel(s)\n".encode())
            return

        if route != "/feed":
            self._send(404, b"not found\n")
            return

        if not self._authorised():
            self._send(401, b"bad key\n")
            return

        name = self._channel()
        if name is None:
            self._send(400, b"bad channel\n")
            return

        with _lock:
            entry = _channels.get(name)

        if entry is None:
            self._send(404, b"no such channel\n")
            return

        self._send(200, entry[0])

    def do_POST(self):
        if urlparse(self.path).path != "/publish":
            self._send(404, b"not found\n")
            return

        if not self._authorised():
            self._send(401, b"bad key\n")
            return

        name = self._channel()
        if name is None:
            self._send(400, b"bad channel\n")
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send(400, b"bad length\n")
            return

        if length <= 0 or length > MAX_BODY:
            self._send(413, b"bad body size\n")
            return

        body = self.rfile.read(length)

        now = time.monotonic()
        with _lock:
            _channels[name] = (body, now)
            _prune(now)

        self._send(200, b"ok\n")

    # Keep the console readable; one line per request is noise at 10 Hz.
    def log_message(self, fmt, *args):
        pass


def main():
    global _key

    ap = argparse.ArgumentParser(description="Sentinal Copier relay")
    ap.add_argument("--key", required=True,
                    help="shared secret; must match InpRelayKey in both EAs")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--host", default="0.0.0.0")
    args = ap.parse_args()

    if len(args.key) < 16:
        raise SystemExit("Use a key of at least 16 characters - this is the only "
                         "thing standing between your feed and the open internet.")

    _key = args.key

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    print(f"Sentinal Copier relay listening on {args.host}:{args.port}")
    print("Master  -> POST /publish?channel=NAME")
    print("Slaves  -> GET  /feed?channel=NAME")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopping")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
