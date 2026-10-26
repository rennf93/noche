#!/usr/bin/env python3
"""Throttled download server for the surfaces probe.

Usage: slow_server.py PORT [REQUEST_LOG]

Files (both about 2 MB/s, with Range, ETag and Last-Modified so a download can resume):
  /big.bin   200 MB
  /mid.bin   24 MB, small enough to finish inside one probe run
  /small.bin 4 KB (profile-clear: a finished download in a profile)
  /hold.html a text/html response that sends its first bytes and then holds the connection open for 120 s (profile-close: a document that stays loading);
             when the client closes the connection the server logs "closed <path and query>" (download-keep-stream: a request must not outlive its tab)
  /auth      HTTP Basic (user noche, password probe): 401 without an Authorization header, 200 with it; every request logs "/auth auth=yes|no"
             (profile-clear: after ClearHttpAuthCredentials the next request must arrive with auth=no)
The body is a deterministic pattern, byte i = (i * 31 + 7) mod 251, so a probe can compute the expected SHA-256 of any
prefix without trusting the app or the engine. Every request is appended to REQUEST_LOG as "<path> range=<Range header>",
the witness for "the resume sent a Range request".
"""
import sys, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

FILES = {"/big.bin": 200 * 1024 * 1024, "/mid.bin": 24 * 1024 * 1024, "/small.bin": 4096}
CHUNK = 64 * 1024
DELAY = 0.03
PERIOD = bytes((i * 31 + 7) % 251 for i in range(251))
TABLE = PERIOD * (CHUNK // 251 + 2)
LOG = sys.argv[2] if len(sys.argv) > 2 else None


def pattern(offset, n):
    i = offset % 251
    return TABLE[i:i + n]


class H(BaseHTTPRequestHandler):
    # HTTP/1.1: net's HasStrongValidators ignores the ETag of an HTTP/1.0 response, and a download without stored validators restarts from byte 0.
    protocol_version = "HTTP/1.1"

    def end_headers(self):
        self.send_header("Connection", "close")  # no keep-alive: bodies are length-less or held open
        super().end_headers()

    def log_message(self, *a): pass

    def do_GET(self):
        path = self.path.split("?")[0]
        rng = self.headers.get("Range")
        if LOG:
            with open(LOG, "a") as f:
                f.write(f"{path} range={rng or '-'}\n")
        if path == "/auth":
            ok = self.headers.get("Authorization") == "Basic bm9jaGU6cHJvYmU="  # noche:probe
            if LOG:
                with open(LOG, "a") as f:
                    f.write(f"/auth auth={'yes' if ok else 'no'}\n")
            body = b"<!doctype html><title>auth</title><p>authenticated" if ok else b"unauthorized"
            self.send_response(200 if ok else 401)
            if not ok: self.send_header("WWW-Authenticate", 'Basic realm="noche-probe"')
            self.send_header("Content-Type", "text/html")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/hold.html":
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            try:
                self.wfile.write(b"<!doctype html><title>hold</title><p>holding the response open"); self.wfile.flush()
                for _ in range(1200):
                    time.sleep(0.1)
                    self.wfile.write(b" "); self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                if LOG:
                    with open(LOG, "a") as f:
                        f.write(f"closed {self.path}\n")
            return
        size = FILES.get(path)
        if size is None:
            self.send_response(404); self.end_headers(); return
        start = 0
        if rng and rng.startswith("bytes="):
            start = int(rng[6:].split("-")[0] or 0)
        name = path[1:]
        self.send_response(206 if start else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", f'attachment; filename="{name}"')
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", f'"noche-probe-{name}"')
        self.send_header("Last-Modified", "Sat, 01 Jan 2022 00:00:00 GMT")
        # Validators alone make the body heuristically fresh, and a later check would get it from the HTTP cache at full speed.
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(size - start))
        if start: self.send_header("Content-Range", f"bytes {start}-{size - 1}/{size}")
        self.end_headers()
        sent = start
        try:
            while sent < size:
                n = min(CHUNK, size - sent)
                self.wfile.write(pattern(sent, n)); self.wfile.flush()
                sent += n
                time.sleep(DELAY)
        except (BrokenPipeError, ConnectionResetError):
            pass


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
