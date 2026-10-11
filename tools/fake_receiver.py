#!/usr/bin/env python3
"""
Stand-in for the TV. Speaks the mactv wire protocol (see ../PROTOCOL.md): accepts one sender at a
time, answers HELLO, records the raw H.264 elementary stream to a file, prints live statistics, and
can pipe the stream into ffplay so you can watch it on the Mac.

    python3 tools/fake_receiver.py --advertise --out /tmp/stream.h264     # then: mactv send --name "Fake TV"
    python3 tools/fake_receiver.py --play                                  # watch live with ffplay
    python3 tools/fake_receiver.py --keyframe-every 3                      # exercise the control channel
"""
import argparse
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time

HEADER = struct.Struct(">BBHQI")  # type, flags, reserved, pts_us, payload length (16 bytes)
HELLO, VIDEO_CONFIG, VIDEO_FRAME, AUDIO_CONFIG, AUDIO_FRAME = 1, 2, 3, 4, 5
HELLO_ACK, REQUEST_KEYFRAME = 0x10, 0x11
FLAG_KEYFRAME = 1
MAX_PAYLOAD = 16 * 1024 * 1024
SERVICE_TYPE = "_mactvmirror._tcp"


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def encode(mtype, flags=0, pts=0, payload=b""):
    return HEADER.pack(mtype, flags, 0, pts, len(payload)) + payload


def recv_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(min(1 << 20, n - len(buf)))
        if not chunk:
            raise ConnectionError("sender closed the connection")
        buf += chunk
    return bytes(buf)


class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.frames = self.keyframes = self.bytes = 0
        self.first_pts = self.last_pts = None
        self.first_wall = self.last_wall = None
        self.width = self.height = None
        self._snap = (0, 0, time.monotonic())

    def add(self, pts, size, key):
        with self.lock:
            now = time.monotonic()
            self.frames += 1
            self.bytes += size
            if key:
                self.keyframes += 1
            if self.first_pts is None:
                self.first_pts, self.first_wall = pts, now
            self.last_pts, self.last_wall = pts, now

    def line(self):
        with self.lock:
            frames, nbytes, t0 = self._snap
            now = time.monotonic()
            dt = max(1e-6, now - t0)
            fps = (self.frames - frames) / dt
            mbps = (self.bytes - nbytes) * 8 / dt / 1e6
            self._snap = (self.frames, self.bytes, now)
            drift = ""
            if self.first_pts is not None and self.last_pts != self.first_pts:
                pts_span = (self.last_pts - self.first_pts) / 1e6
                wall_span = self.last_wall - self.first_wall
                drift = f", pts-vs-wall drift {1000 * (wall_span - pts_span):+.0f} ms"
            return (f"{fps:5.1f} fps, {mbps:5.2f} Mbit/s, {self.frames} frames "
                    f"({self.keyframes} key){drift}")


def serve_client(sock, addr, args, out, play, stats, stop_event):
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    sock.settimeout(10)
    send_lock = threading.Lock()

    def send(mtype, payload=b""):
        with send_lock:
            sock.sendall(encode(mtype, payload=payload))

    def keyframe_nagger():
        while not stop_event.is_set():
            if stop_event.wait(args.keyframe_every):
                return
            log("→ REQUEST_KEYFRAME")
            try:
                send(REQUEST_KEYFRAME)
            except OSError:
                return

    if args.keyframe_every > 0:
        threading.Thread(target=keyframe_nagger, daemon=True).start()

    while not stop_event.is_set():
        mtype, flags, _, pts, length = HEADER.unpack(recv_exact(sock, HEADER.size))
        if length > MAX_PAYLOAD:
            raise ConnectionError(f"oversized payload {length}")
        payload = recv_exact(sock, length)

        if mtype == HELLO:
            info = json.loads(payload.decode("utf-8", "replace"))
            stats.width, stats.height = info.get("width"), info.get("height")
            log(f"HELLO {info}")
            ack = json.dumps({"v": 1, "name": args.name, "maxWidth": 1920, "maxHeight": 1080}).encode()
            send(HELLO_ACK, ack)
        elif mtype == VIDEO_CONFIG:
            log(f"VIDEO_CONFIG {length} bytes: {payload[:24].hex(' ')}…")
            # Not written to the file: keyframes carry SPS/PPS in-band already.
        elif mtype == VIDEO_FRAME:
            key = bool(flags & FLAG_KEYFRAME)
            stats.add(pts, length, key)
            if out:
                out.write(payload)
            if play:
                try:
                    play.stdin.write(payload)
                except (BrokenPipeError, ValueError):
                    play = None
            if args.exit_after_frames and stats.frames >= args.exit_after_frames:
                log(f"reached {args.exit_after_frames} frames, closing")
                return
        else:
            log(f"ignoring message type {mtype:#x} ({length} bytes)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=7000)
    ap.add_argument("--out", help="write the raw H.264 elementary stream here (ffplay/ffprobe can read it)")
    ap.add_argument("--play", action="store_true", help="pipe the stream into ffplay")
    ap.add_argument("--advertise", action="store_true", help="advertise over Bonjour with dns-sd")
    ap.add_argument("--name", default="Fake TV", help="Bonjour service name (default: Fake TV)")
    ap.add_argument("--keyframe-every", type=float, default=0, metavar="SEC",
                    help="send REQUEST_KEYFRAME every SEC seconds (0 = off)")
    ap.add_argument("--exit-after-frames", type=int, default=0, metavar="N",
                    help="close the connection and exit after N frames (for scripted tests)")
    ap.add_argument("--once", action="store_true", help="exit after the first sender disconnects")
    args = ap.parse_args()

    advertiser = None
    if args.advertise:
        if not shutil.which("dns-sd"):
            sys.exit("dns-sd not found; --advertise only works on macOS")
        advertiser = subprocess.Popen(["dns-sd", "-R", args.name, SERVICE_TYPE, ".", str(args.port)],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log(f'advertising "{args.name}" as {SERVICE_TYPE} on port {args.port}')

    play = None
    if args.play:
        if not shutil.which("ffplay"):
            sys.exit("ffplay not found (brew install ffmpeg)")
        play = subprocess.Popen(
            ["ffplay", "-hide_banner", "-loglevel", "warning", "-fflags", "nobuffer", "-flags", "low_delay",
             "-framedrop", "-probesize", "32", "-analyzeduration", "0", "-f", "h264", "-i", "-"],
            stdin=subprocess.PIPE)

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", args.port))
    server.listen(1)
    log(f"listening on port {args.port}" + (f", recording to {args.out}" if args.out else ""))

    stop_event = threading.Event()
    try:
        while True:
            sock, addr = server.accept()
            log(f"sender connected from {addr[0]}:{addr[1]}")
            stats = Stats()
            out = open(args.out, "wb") if args.out else None
            ticker_stop = threading.Event()

            def ticker():
                while not ticker_stop.wait(1.0):
                    log(stats.line())

            threading.Thread(target=ticker, daemon=True).start()
            try:
                serve_client(sock, addr, args, out, play, stats, stop_event)
            except (ConnectionError, socket.timeout, OSError) as e:
                log(f"disconnected: {e}")
            finally:
                ticker_stop.set()
                sock.close()
                if out:
                    out.close()
                log(f"session: {stats.line()}")
                if args.out:
                    log(f"wrote {os.path.getsize(args.out)} bytes to {args.out}")
            if args.once or args.exit_after_frames:
                break
    except KeyboardInterrupt:
        pass
    finally:
        stop_event.set()
        server.close()
        if play and play.stdin:
            try:
                play.stdin.close()
            except OSError:
                pass
        if advertiser:
            advertiser.terminate()


if __name__ == "__main__":
    main()
