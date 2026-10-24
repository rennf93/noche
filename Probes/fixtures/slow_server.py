#!/usr/bin/env python3
"""Throttled download server for the surfaces probe: /big.bin is 200 MB of zeros at about 2 MB/s, with Range, ETag and Last-Modified so a download can resume."""
import sys, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

SIZE = 200 * 1024 * 1024
CHUNK = 64 * 1024
DELAY = 0.03

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.split("?")[0] != "/big.bin":
            self.send_response(404); self.end_headers(); return
        start = 0
        rng = self.headers.get("Range")
        if rng and rng.startswith("bytes="):
            start = int(rng[6:].split("-")[0] or 0)
        self.send_response(206 if start else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", 'attachment; filename="big.bin"')
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", '"noche-probe-big"')
        self.send_header("Last-Modified", "Sat, 01 Jan 2022 00:00:00 GMT")
        self.send_header("Content-Length", str(SIZE - start))
        if start: self.send_header("Content-Range", f"bytes {start}-{SIZE - 1}/{SIZE}")
        self.end_headers()
        buf = b"\0" * CHUNK
        sent = start
        try:
            while sent < SIZE:
                n = min(CHUNK, SIZE - sent)
                self.wfile.write(buf[:n]); self.wfile.flush()
                sent += n
                time.sleep(DELAY)
        except (BrokenPipeError, ConnectionResetError):
            pass

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
