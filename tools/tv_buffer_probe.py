#!/usr/bin/env python3
"""
Measure how the TV's DLNA player buffers, from the server side.

Serves a pre-encoded MPEG-TS file as fast as the TV will take it and records bytes-accepted over
time. A player that pre-buffers by BYTES takes the same initial burst regardless of bitrate; one
that pre-buffers by TIME takes a burst proportional to the bitrate. The steady-state slope is the
file's bitrate (the player throttles to real time once its buffer is full).

  python3 tools/tv_buffer_probe.py file.ts --seconds 40
"""
import argparse
import os
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dlna_push import Renderer, discover, local_ip, log  # noqa: E402

samples = []          # (t, bytes accepted by the TV's TCP stack)
t_get = [None]


class FileHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    path_on_disk = None
    features = "DLNA.ORG_PN=AVC_TS_MP_HD_AAC_ISO;DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"

    def log_message(self, fmt, *args):
        pass

    def _headers(self):
        self.send_response(200)
        self.send_header("Content-Type", "video/mpeg")
        self.send_header("transferMode.dlna.org", "Streaming")
        self.send_header("contentFeatures.dlna.org", self.features)
        self.send_header("Accept-Ranges", "none")
        self.send_header("Connection", "close")
        self.end_headers()

    def do_HEAD(self):
        log("http HEAD from TV")
        self._headers()

    def do_GET(self):
        log("http GET from TV; serving file as fast as it reads")
        self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 32 * 1024)   # keep our side's buffer small
        self._headers()
        t_get[0] = time.monotonic()
        sent = 0
        try:
            with open(self.path_on_disk, "rb") as f:
                while True:
                    chunk = f.read(16 * 1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)            # blocks once the TV stops reading
                    sent += len(chunk)
                    samples.append((time.monotonic() - t_get[0], sent))
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        log(f"TV closed the stream after {sent // 1000} kB")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--seconds", type=float, default=40)
    ap.add_argument("--port", type=int, default=8092)
    ap.add_argument("--bitrate", type=float, default=0, help="nominal Mbit/s of the file, for the summary")
    args = ap.parse_args()

    tv = discover()[0]
    log(f"using {tv.manufacturer} {tv.model}")
    FileHandler.path_on_disk = args.file
    httpd = ThreadingHTTPServer(("0.0.0.0", args.port), FileHandler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    url = f"http://{local_ip()}:{args.port}/probe.ts"
    tv.set_uri(url, "video/mpeg", FileHandler.features, title="buffer probe")
    t_play = time.monotonic()
    tv.play()
    log("Play sent")
    last = None
    while time.monotonic() - t_play < args.seconds:
        try:
            st = tv.state()
        except Exception as e:
            st = (f"error: {e}", "")
        if st != last:
            got = samples[-1][1] if samples else 0
            log(f"TV state={st[0]} after {got // 1000} kB accepted")
            last = st
        time.sleep(0.25)
    try:
        tv.stop()
    except Exception as e:
        log(f"Stop failed: {e}")
    httpd.shutdown()

    if not samples:
        log("the TV never fetched the stream")
        return
    print("\n   t(s)   accepted kB   (bytes the TV's TCP stack had taken by that time)")
    marks = [0.25, 0.5, 1, 1.5, 2, 3, 4, 5, 7, 10, 15, 20, 30]
    i = 0
    for m in marks:
        while i < len(samples) and samples[i][0] < m:
            i += 1
        if i == 0:
            continue
        print(f"   {m:5.2f}   {samples[i - 1][1] // 1000:10d}")
    # burst = bytes taken in the first 1.5 s minus the steady-state rate's share
    late = [s for s in samples if s[0] >= 10]
    if len(late) > 2:
        rate = (late[-1][1] - late[0][1]) / (late[-1][0] - late[0][0])    # bytes/s steady state
        burst_samples = [s for s in samples if s[0] <= 1.5]
        burst = burst_samples[-1][1] - rate * burst_samples[-1][0] if burst_samples else 0
        print(f"\n   steady-state rate ≈ {rate * 8 / 1e6:.2f} Mbit/s; initial burst above real time ≈ {burst / 1e6:.2f} MB "
              f"= {burst / max(rate, 1):.2f} s of content")


if __name__ == "__main__":
    main()
