#!/usr/bin/env python3
"""
DLNA path for TVs that cannot run the receiver app (TCL's Linux-based sets expose a UPnP MediaRenderer).

The Mac serves a live MPEG-TS stream over HTTP and tells the TV to play it via UPnP AVTransport.
ffmpeg does capture+encode+mux here so the path can be iterated on in minutes; the Swift sender
gets a native version once we know what the TV's player tolerates.

  python3 tools/dlna_push.py --source test                 # colour bars + running clock, no permissions needed
  python3 tools/dlna_push.py --source screen               # mirror the screen (needs Screen Recording for your terminal)
  python3 tools/dlna_push.py --source screen --screen 1    # another display (see `ffmpeg -f avfoundation -list_devices true -i ""`)
  python3 tools/dlna_push.py --stop                        # just send Stop to the TV

Three independent knobs (see --preset for bundles):
  --bitrate        VIDEO quality.   --audio-bitrate  AUDIO quality.   --muxrate  DELAY (see below).

Latency knobs (defaults are the low-latency set):
  --muxrate 7M     pad the stream to a constant bitrate with null packets. This TV pre-buffers
                   about 2 MB before showing anything, so latency ≈ 2 MB / bitrate. Its Wi-Fi link
                   maxes out near 10 Mbit/s, so 7M is the safe ceiling. 0 = off.
  --gop 1          keyframe interval in seconds (startup / recovery speed).
  --audio-device   loopback device carrying the Mac's output ('auto' finds AirBeamTV Audio / BlackHole).
                   Set System Settings → Sound → Output to that device so the Mac's audio flows into it.
  --no-audio       drop the audio track entirely (some players wait for audio before showing video).
  --pes 512        max PES payload bytes; small keeps audio from being batched into ~0.4 s lumps.

Ctrl-C stops the TV and exits.
"""
import argparse
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from xml.sax.saxutils import escape

SSDP_ADDR = ("239.255.255.250", 1900)
RENDERER = "urn:schemas-upnp-org:device:MediaRenderer:1"
NS = {"u": "urn:schemas-upnp-org:device-1-0"}
T0 = time.monotonic()


def log(msg):
    print(f"{time.strftime('%H:%M:%S')} +{time.monotonic() - T0:6.2f}s  {msg}", flush=True)


def local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    finally:
        s.close()


# ---------------------------------------------------------------- UPnP control point

class Renderer:
    def __init__(self, location):
        self.location = location
        self.host = re.match(r"https?://([^/]+)", location).group(1)
        xml = urllib.request.urlopen(location, timeout=5).read()
        root = ET.fromstring(xml)
        dev = root.find("u:device", NS)
        self.manufacturer = dev.findtext("u:manufacturer", default="?", namespaces=NS)
        self.model = (dev.findtext("u:modelDescription", default="", namespaces=NS)
                      or dev.findtext("u:modelName", default="?", namespaces=NS))
        self.base = root.findtext("u:URLBase", namespaces=NS) or f"http://{self.host}"
        self.services = {}
        for svc in dev.findall(".//u:service", NS):
            stype = svc.findtext("u:serviceType", namespaces=NS)
            ctrl = svc.findtext("u:controlURL", namespaces=NS)
            self.services[stype] = ctrl if ctrl.startswith("http") else self.base.rstrip("/") + "/" + ctrl.lstrip("/")

    def soap(self, service, action, args="", timeout=8):
        stype = f"urn:schemas-upnp-org:service:{service}:1"
        body = (f'<?xml version="1.0" encoding="utf-8"?>'
                f'<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
                f's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
                f'<u:{action} xmlns:u="{stype}">{args}</u:{action}></s:Body></s:Envelope>').encode()
        req = urllib.request.Request(self.services[stype], data=body, headers={
            "Content-Type": 'text/xml; charset="utf-8"', "SOAPAction": f'"{stype}#{action}"'})
        try:
            return urllib.request.urlopen(req, timeout=timeout).read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")
            code = re.search(r"<errorCode>(\d+)</errorCode>", detail)
            desc = re.search(r"<errorDescription>(.*?)</errorDescription>", detail)
            raise RuntimeError(f"{action} failed: UPnP error {code.group(1) if code else e.code} "
                               f"{desc.group(1) if desc else ''}".strip())

    def protocol_info(self):
        resp = self.soap("ConnectionManager", "GetProtocolInfo")
        sink = re.search(r"<Sink>(.*?)</Sink>", resp, re.S)
        return [e.strip() for e in (sink.group(1) if sink else "").replace("&lt;", "<").split(",") if e.strip()]

    def set_uri(self, url, mime, features, title="Mac screen"):
        didl = (f'<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
                f'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
                f'xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">'
                f'<item id="0" parentID="-1" restricted="1"><dc:title>{escape(title)}</dc:title>'
                f'<upnp:class>object.item.videoItem</upnp:class>'
                f'<res protocolInfo="http-get:*:{mime}:{features}">{escape(url)}</res></item></DIDL-Lite>')
        self.soap("AVTransport", "SetAVTransportURI",
                  f"<InstanceID>0</InstanceID><CurrentURI>{escape(url)}</CurrentURI>"
                  f"<CurrentURIMetaData>{escape(didl)}</CurrentURIMetaData>")

    def play(self):
        self.soap("AVTransport", "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>")

    def stop(self):
        self.soap("AVTransport", "Stop", "<InstanceID>0</InstanceID>")

    def state(self):
        resp = self.soap("AVTransport", "GetTransportInfo", "<InstanceID>0</InstanceID>", timeout=3)
        st = re.search(r"<CurrentTransportState>(.*?)</CurrentTransportState>", resp)
        status = re.search(r"<CurrentTransportStatus>(.*?)</CurrentTransportStatus>", resp)
        return (st.group(1) if st else "?", status.group(1) if status else "?")


def discover(seconds=3.0, prefer_host=None):
    ip = local_ip()
    msg = (f"M-SEARCH * HTTP/1.1\r\nHOST: {SSDP_ADDR[0]}:{SSDP_ADDR[1]}\r\nMAN: \"ssdp:discover\"\r\n"
           f"MX: 2\r\nST: {RENDERER}\r\n\r\n").encode()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(ip))
    s.bind((ip, 0))
    s.settimeout(0.5)
    for _ in range(2):
        s.sendto(msg, SSDP_ADDR)
    found = {}
    end = time.time() + seconds
    while time.time() < end:
        try:
            data, addr = s.recvfrom(4096)
        except socket.timeout:
            continue
        m = re.search(r"^LOCATION:\s*(\S+)", data.decode("utf-8", "replace"), re.I | re.M)
        if m:
            found[addr[0]] = m.group(1)
    renderers = []
    for host, loc in found.items():
        try:
            r = Renderer(loc)
            if any("AVTransport" in k for k in r.services):
                renderers.append(r)
        except Exception as e:
            log(f"skipping {host}: {e}")
    if prefer_host:
        renderers.sort(key=lambda r: 0 if r.host.startswith(prefer_host) else 1)
    return renderers


# ---------------------------------------------------------------- live MPEG-TS over HTTP

class Broadcaster:
    """Fans ffmpeg's MPEG-TS output out to HTTP clients as soon as bytes exist (no chunk batching)."""
    def __init__(self):
        self.clients = []
        self.lock = threading.Lock()
        self.bytes = 0
        self.first_byte_at = None

    def pump(self, pipe):
        fd = pipe.fileno()
        while True:
            chunk = os.read(fd, 65536)          # returns whatever ffmpeg has written so far
            if not chunk:
                break
            if self.first_byte_at is None:
                self.first_byte_at = time.monotonic()
            self.bytes += len(chunk)
            with self.lock:
                for q in list(self.clients):
                    if len(q) > 4000:           # client stopped reading for a long time: cut it loose
                        self.clients.remove(q)
                        continue
                    q.append(chunk)

    def subscribe(self):
        q = []
        with self.lock:
            self.clients.append(q)
        return q

    def unsubscribe(self, q):
        with self.lock:
            if q in self.clients:
                self.clients.remove(q)


class StreamHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    broadcaster = None
    mime = "video/mpeg"
    features = ""
    events = []          # (monotonic time, description) for the latency report

    def log_message(self, fmt, *args):
        pass

    def _headers(self):
        self.send_response(200)
        self.send_header("Content-Type", self.mime)
        self.send_header("transferMode.dlna.org", "Streaming")
        self.send_header("contentFeatures.dlna.org", self.features)
        self.send_header("Accept-Ranges", "none")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

    def do_HEAD(self):
        log(f"http HEAD from TV (UA={self.headers.get('User-Agent', '-')[:50]})")
        self._headers()

    def do_GET(self):
        log(f"http GET from TV (UA={self.headers.get('User-Agent', '-')[:50]}); streaming")
        self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self._headers()
        q = self.broadcaster.subscribe()
        sent = 0
        try:
            while True:
                if q:
                    chunk = q.pop(0)
                    self.wfile.write(chunk)
                    sent += len(chunk)
                else:
                    time.sleep(0.002)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            self.broadcaster.unsubscribe(q)
            log(f"TV closed the stream after {sent // 1000} kB")


LOOPBACK_DEVICES = ("AirBeamTV Audio", "BlackHole", "Loopback", "Soundflower", "Virtual Cable")

# Measured on this TCL set: it pre-buffers ~2 MB before showing anything, and its Wi-Fi intake
# tops out near 9.7 Mbit/s. Delay ≈ PREBUFFER / muxrate, plus a fixed ~0.3 s for capture+encode+network.
TV_PREBUFFER_BYTES = 2_000_000
TV_LINK_LIMIT_BPS = 9_500_000
FIXED_DELAY_S = 0.3
TS_OVERHEAD = 1.15          # TS/PES packaging overhead with small PES payloads

PRESETS = {
    #                size         fps  video   audio   muxrate   → quality / delay
    "lowlatency": dict(size="1280x720",  fps=30, bitrate="2.5M", audio_bitrate="96k",  muxrate="8M"),
    "balanced":   dict(size="1280x720",  fps=30, bitrate="4M",   audio_bitrate="128k", muxrate="7M"),
    "quality":    dict(size="1920x1080", fps=30, bitrate="6M",   audio_bitrate="160k", muxrate="8M"),
}


def parse_rate(text):
    """'4M' → 4000000, '128k' → 128000, '0' → 0."""
    m = re.fullmatch(r"\s*([0-9.]+)\s*([kKmM]?)\s*", str(text))
    if not m:
        raise ValueError(f"bad bitrate {text!r} (use e.g. 4M or 128k)")
    return int(float(m.group(1)) * {"": 1, "k": 1e3, "K": 1e3, "m": 1e6, "M": 1e6}[m.group(2)])


def apply_preset_and_check(args):
    """Fill unset knobs from the preset, then sanity-check the combination against the TV's limits."""
    preset = PRESETS[args.preset]
    for key, value in preset.items():
        if getattr(args, key) is None:
            setattr(args, key, value)
    video = parse_rate(args.bitrate)
    audio = parse_rate(args.audio_bitrate) if args.audio else 0
    mux = parse_rate(args.muxrate)
    payload = (video + audio) * TS_OVERHEAD
    problems, notes = [], []
    if mux:
        if payload > mux:
            need = int(payload / 1e6 * 10 + 1) / 10
            problems.append(f"video {args.bitrate} + audio {args.audio_bitrate if args.audio else 'off'} (+ ~15% packaging) exceeds "
                            f"--muxrate {args.muxrate}; raise --muxrate to ≥ {need}M or lower --bitrate")
        if mux > TV_LINK_LIMIT_BPS:
            notes.append(f"--muxrate {args.muxrate} is above the ~{TV_LINK_LIMIT_BPS / 1e6:.1f} Mbit/s this TV "
                         f"managed over Wi-Fi; expect stalls unless the TV is on Ethernet")
        delay = TV_PREBUFFER_BYTES * 8 / mux + FIXED_DELAY_S
        notes.append(f"expected delay ≈ {delay:.1f} s  (TV pre-buffers ~2 MB at {mux / 1e6:.1f} Mbit/s)")
    else:
        delay = TV_PREBUFFER_BYTES * 8 / max(video, 1) + FIXED_DELAY_S
        notes.append(f"no padding: delay ≈ {delay:.1f} s at full {args.bitrate}, *much* more when the screen is static")
    args.expected_delay = delay
    return problems, notes


def list_audio_devices():
    """Names of avfoundation audio devices, as ffmpeg reports them."""
    out = subprocess.run(["ffmpeg", "-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""],
                         capture_output=True, text=True).stderr
    names, in_audio = [], False
    for line in out.splitlines():
        if "audio devices" in line:
            in_audio = True
        elif "video devices" in line:
            in_audio = False
        elif in_audio:
            m = re.search(r"\[\d+\] (.+)$", line)
            if m:
                names.append(m.group(1).strip())
    return names


def resolve_audio_device(wanted):
    """'none' → None (silent track). 'auto' → first loopback driver found. Anything else → verbatim."""
    if wanted == "none":
        return None
    devices = list_audio_devices()
    if wanted == "auto":
        for name in devices:
            if any(name.lower().startswith(k.lower()) for k in LOOPBACK_DEVICES):
                return name
        log("no loopback audio device found (AirBeamTV Audio / BlackHole / Loopback); sending silence. "
            "Install one with `brew install blackhole-2ch` to mirror system audio.")
        return None
    if wanted not in devices:
        log(f"audio device \"{wanted}\" not found; ffmpeg sees: {', '.join(devices) or 'none'}")
    return wanted


def ffmpeg_command(args):
    live_audio = args.source == "screen" and args.audio_device is not None
    if args.source == "test":
        src = ["-re", "-f", "lavfi", "-i", f"testsrc=size={args.size}:rate={args.fps}"]
    else:
        # One avfoundation input carries both the screen and (optionally) the loopback audio device.
        device = f"{args.screen}:{args.audio_device}" if live_audio else f"{args.screen}:none"
        src = ["-fflags", "+nobuffer", "-thread_queue_size", "512", "-f", "avfoundation", "-capture_cursor", "1",
               "-framerate", str(args.fps), "-pixel_format", "uyvy422", "-i", device]
    if live_audio:
        audio = ["-c:a", "aac", "-b:a", args.audio_bitrate, "-ar", "48000", "-ac", "2"]
    elif args.audio:
        audio = ["-re", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-c:a", "aac", "-b:a", "48k"]
    else:
        audio = ["-an"]
    scale = (["-vf", f"scale={args.size}:flags=fast_bilinear,format=yuv420p"] if args.source == "screen"
             else ["-pix_fmt", "yuv420p"])
    gop = max(1, int(args.fps * args.gop))
    if args.encoder == "videotoolbox":
        venc = ["-c:v", "h264_videotoolbox", "-realtime", "1", "-prio_speed", "1", "-b:v", args.bitrate,
                "-profile:v", "main", "-g", str(gop), "-bf", "0"]
    else:
        venc = ["-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-profile:v", "main",
                "-b:v", args.bitrate, "-g", str(gop), "-bf", "0"]
    cbr = bool(args.muxrate and args.muxrate != "0")
    # With a constant mux rate the PCR is byte-position based, so a frame's packets are spread over
    # its time slot; a small muxdelay keeps DTS >= PCR (otherwise ffmpeg warns "dts < pcr, TS is invalid").
    mux = ["-muxdelay", "0.15" if cbr else "0", "-muxpreload", "0", "-flush_packets", "1",
           "-pes_payload_size", str(args.pes), "-mpegts_flags", "resend_headers+initial_discontinuity"]
    if cbr:
        mux += ["-muxrate", args.muxrate, "-pcr_period", "20"]
    return (["ffmpeg", "-hide_banner", "-loglevel", "warning", "-nostdin"] + src + audio + scale + venc + mux +
            ["-f", "mpegts", "-"])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", choices=["test", "screen"], default="test")
    ap.add_argument("--screen", default="1", help="avfoundation screen index (default 1 = first display on most Macs)")
    ap.add_argument("--preset", choices=sorted(PRESETS), default="balanced",
                    help="starting point for size/fps/bitrate/audio-bitrate/muxrate; any explicit flag overrides it")
    ap.add_argument("--size", help="capture/encode size, e.g. 1280x720 or 1920x1080")
    ap.add_argument("--fps", type=int)
    ap.add_argument("--bitrate", help="VIDEO quality: H.264 bitrate, e.g. 2.5M, 4M, 6M")
    ap.add_argument("--audio-bitrate", help="AUDIO quality: AAC bitrate, e.g. 96k, 128k, 160k")
    ap.add_argument("--muxrate", help="DELAY: total wire rate with null-packet padding (0 = off). "
                                      "The TV pre-buffers ~2 MB, so delay ≈ 16 Mbit / muxrate; keep ≤ ~9M on Wi-Fi")
    ap.add_argument("--dry-run", action="store_true", help="print the resolved settings and ffmpeg command, then exit")
    ap.add_argument("--gop", type=float, default=1.0, help="keyframe interval in seconds (startup/recovery speed)")
    ap.add_argument("--pes", type=int, default=512, help="max PES payload size in bytes")
    ap.add_argument("--encoder", choices=["videotoolbox", "x264"], default="videotoolbox")
    ap.add_argument("--audio-device", default="auto",
                    help="avfoundation audio device carrying the Mac's output: 'auto' (first loopback driver found, "
                         "e.g. AirBeamTV Audio or BlackHole), a device name, or 'none' for a silent track")
    ap.add_argument("--no-audio", dest="audio", action="store_false", help="omit the audio track entirely")
    ap.add_argument("--mime", default="video/mpeg", help="MIME type advertised to the TV (video/mpeg or video/mp2t)")
    ap.add_argument("--pn", default="AVC_TS_MP_HD_AAC_ISO",
                    help="DLNA.ORG_PN profile to claim (TCL lists AVC_TS_MP_HD_AAC_ISO for H.264+AAC in plain TS); '' to omit")
    ap.add_argument("--flags", default="01700000000000000000000000000000", help="DLNA.ORG_FLAGS value")
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument("--tv", help="TV IP (skips SSDP discovery)")
    ap.add_argument("--seconds", type=float, default=0, help="stop automatically after N seconds (0 = until Ctrl-C)")
    ap.add_argument("--stop", action="store_true", help="only send Stop to the TV and exit")
    args = ap.parse_args()

    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg not found (brew install ffmpeg)")
    try:
        problems, notes = apply_preset_and_check(args)
    except ValueError as e:
        sys.exit(str(e))
    log(f"preset {args.preset}: {args.size} @ {args.fps} fps, video {args.bitrate}, "
        f"audio {args.audio_bitrate if args.audio else 'off'}, wire {args.muxrate if args.muxrate != '0' else 'unpadded'}")
    for n in notes:
        log(n)
    for p in problems:
        log("problem: " + p)
    if problems:
        sys.exit(1)
    if args.dry_run:
        if args.source == "screen" and args.audio:
            args.audio_device = resolve_audio_device(args.audio_device)
        else:
            args.audio_device = None
        print("ffmpeg " + " ".join(ffmpeg_command(args)[1:]))
        return
    if args.source == "screen" and args.audio:
        args.audio_device = resolve_audio_device(args.audio_device)
        if args.audio_device:
            log(f"system audio via \"{args.audio_device}\" — set the Mac's sound output to that device "
                f"(or a Multi-Output Device that includes it), and allow Microphone access for your terminal")
    else:
        args.audio_device = None

    log("looking for a DLNA renderer…")
    renderers = discover(prefer_host=args.tv)
    if args.tv:
        renderers = [r for r in renderers if r.host.startswith(args.tv)]
    if not renderers:
        sys.exit("no MediaRenderer found. Is the TV on and on the same Wi-Fi?")
    tv = renderers[0]
    log(f"using {tv.manufacturer} {tv.model}")

    if args.stop:
        tv.stop()
        log("sent Stop")
        return

    ip = local_ip()
    url = f"http://{ip}:{args.port}/live.ts"
    bc = Broadcaster()
    StreamHandler.broadcaster = bc
    StreamHandler.mime = args.mime
    features = (f"DLNA.ORG_PN={args.pn};" if args.pn else "") + f"DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS={args.flags}"
    StreamHandler.features = features
    httpd = ThreadingHTTPServer(("0.0.0.0", args.port), StreamHandler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    cmd = ffmpeg_command(args)
    log("ffmpeg " + " ".join(cmd[1:]))
    ff = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    threading.Thread(target=bc.pump, args=(ff.stdout,), daemon=True).start()

    def ffmpeg_stderr():
        for line in ff.stderr:
            log("ffmpeg: " + line.decode("utf-8", "replace").rstrip())
    threading.Thread(target=ffmpeg_stderr, daemon=True).start()

    for _ in range(100):
        if bc.bytes > 0 or ff.poll() is not None:
            break
        time.sleep(0.05)
    if ff.poll() is not None:
        sys.exit(f"ffmpeg exited early with {ff.returncode}")

    log(f"serving {url} as {args.mime} [{features}]")
    stopped = threading.Event()

    def shutdown(*_):
        if stopped.is_set():
            return
        stopped.set()
        log("stopping")
        try:
            tv.stop()
        except Exception as e:
            log(f"Stop failed: {e}")
        ff.terminate()
        httpd.shutdown()

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    try:
        tv.set_uri(url, args.mime, features)
        t_play = time.monotonic()
        tv.play()
        log(f"Play accepted by TV ({(time.monotonic() - t_play) * 1000:.0f} ms)")
    except Exception as e:
        log(f"TV refused: {e}")
        shutdown()
        return

    last = None
    t_start = time.monotonic()
    playing_at = None
    while not stopped.is_set():
        try:
            st = tv.state()
        except Exception as e:
            st = (f"error: {e}", "")
        if st != last:
            log(f"TV state={st[0]} status={st[1]}  served={bc.bytes // 1000} kB")
            if st[0] == "PLAYING" and playing_at is None:
                playing_at = time.monotonic()
                log(f"==> TV reached PLAYING {playing_at - t_play:.2f} s after Play, after {bc.bytes // 1000} kB "
                    f"(~{bc.bytes * 8 / 1e6 / max(0.01, playing_at - t_play):.1f} Mbit/s average)")
            last = st
        if args.seconds and time.monotonic() - t_start > args.seconds:
            shutdown()
            break
        if ff.poll() is not None:
            log(f"ffmpeg exited with {ff.returncode}")
            shutdown()
            break
        time.sleep(0.25)
    log(f"served {bc.bytes // 1000} kB total")


if __name__ == "__main__":
    main()
