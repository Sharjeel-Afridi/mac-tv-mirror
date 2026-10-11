# mac-tv-mirror

Screen mirroring from a MacBook to a TCL TV, built from scratch.

The TV turned out to be TCL's **Linux** platform (a UPnP/DLNA media renderer, not Google TV), so the
working path is **DLNA**: the Mac serves a live MPEG-TS stream over HTTP and tells the TV to play it.
An Android TV receiver app is also here for Google TV sets. See [PLAN.md](PLAN.md).

```
tools/dlna_push.py      ← start here: mirrors to the TCL TV via DLNA (ffmpeg-based prototype)
sender-macos/           Swift Package: `mactv` CLI (ScreenCaptureKit → VideoToolbox → TCP); native DLNA next
receiver-androidtv/     Android TV app (parked: not installable on a Linux TCL set)
tools/fake_receiver.py  Stand-in for the Android receiver; records the stream to .h264
tools/e2e_test.sh       One-shot check of the Swift sender against the fake receiver
PROTOCOL.md             Wire format used by the Swift sender ↔ Android receiver
```

## Mirror to the TCL TV (DLNA)

Requirements: the TV on and on the same Wi-Fi, `ffmpeg` (`brew install ffmpeg`), Python 3.

```bash
python3 tools/dlna_push.py --source test            # colour bars + clock on the TV, no permissions needed
python3 tools/dlna_push.py --source screen          # mirror the screen (grant Screen Recording to Terminal when asked)
python3 tools/dlna_push.py --stop                   # tell the TV to stop
```

Ctrl-C sends Stop to the TV and exits. The log shows the resolved settings, the expected delay, and
the TV's transport state.

### Quality vs delay: three separate knobs

| Flag | Controls | Why |
|---|---|---|
| `--bitrate` | **video quality** | H.264 encoder bitrate. More = sharper text and smoother motion. |
| `--audio-bitrate` | **audio quality** | AAC bitrate. 96k is fine for speech, 160k for music. |
| `--muxrate` | **delay** | Total rate on the wire, padded with empty packets. The TV waits for ~2 MB before it shows anything, so delay ≈ 16 Mbit ÷ muxrate (+ ~0.3 s). |

Rules the tool enforces: video + audio (+15 % packaging) must fit inside `--muxrate`, and over this
TV's Wi-Fi anything above ~9 Mbit/s stalls. On Ethernet you can go higher (`--muxrate 16M` ≈ 1.3 s).

Presets bundle the three (any explicit flag overrides its preset value):

| `--preset` | Size | Video | Audio | Wire | Delay |
|---|---|---|---|---|---|
| `lowlatency` | 1280×720 | 2.5M | 96k | 8M | ≈ 2.3 s |
| `balanced` (default) | 1280×720 | 4M | 128k | 7M | ≈ 2.6 s |
| `quality` | 1920×1080 | 6M | 160k | 8M | ≈ 2.3 s, least Wi-Fi headroom |

`--dry-run` prints the resolved settings, the delay estimate and the ffmpeg command without touching the TV.
Other options: `--fps 30 --gop 1 --encoder videotoolbox|x264 --screen 1 --port 8090 --tv <ip> --seconds N`.

Latency check: open a stopwatch on the Mac, mirror, photograph Mac and TV together.

### Audio

ffmpeg cannot read the Mac's speaker output directly; it needs a *loopback* audio device that the
system plays into. This Mac already has one, **AirBeamTV Audio** (left behind by the AirBeamTV app);
**BlackHole** (`brew install blackhole-2ch`) is the usual free alternative.

1. System Settings → Sound → Output → choose **AirBeamTV Audio**. The Mac's speakers go quiet
   and the audio goes to the TV instead. To hear it on both, build a Multi-Output Device in
   *Audio MIDI Setup* (speakers + AirBeamTV Audio) and pick that as the output.
2. Run `python3 tools/dlna_push.py --source screen`. It finds the loopback device by itself
   (`--audio-device auto`); macOS will ask for **Microphone** access for your terminal the first time.
3. Audio arrives with the same ~2 s delay as the picture, in sync with it.

Explicit choice: `--audio-device "BlackHole 2ch"`. Silent placeholder track: `--audio-device none`.

## Swift sender (for the Android receiver; native DLNA `cast` command is next)

Requirements: macOS 14+, Xcode Command Line Tools (full Xcode not needed).

```bash
cd sender-macos && swift build -c release
```

Commands (binary at `sender-macos/.build/release/mactv`):

```bash
mactv list                         # capturable displays
mactv discover                     # find TVs running the receiver
mactv send --name "TCL TV"         # mirror display 0 to the TV found by name
mactv send --host 192.168.1.50     # ...or by IP
mactv selftest --host 192.168.1.50 # stream a test pattern; no screen permission needed
mactv record --out out.h264 --seconds 5   # capture to a file; `ffplay out.h264` to check
```

Options: `--display N --fps 30 --bitrate 8000000 --max-width 1920 --max-height 1080 --no-cursor --port 7000 --verbose`.

**Screen Recording permission:** the first `send`/`list`/`record` prompts for it. macOS grants it to
the *terminal app* that launched `mactv` (Terminal, iTerm, …): System Settings → Privacy & Security →
Screen & System Audio Recording. Re-run after enabling.

## Testing without the TV

```bash
python3 tools/fake_receiver.py --advertise --out /tmp/stream.h264   # terminal 1
sender-macos/.build/release/mactv selftest --name "Fake TV"          # terminal 2
ffprobe /tmp/stream.h264            # or: ffplay -f h264 /tmp/stream.h264
```

`fake_receiver.py --play` pipes the live stream into ffplay so you can watch it on the Mac.

One-shot check of the whole Mac side (build, discover, stream, validate with ffprobe):

```bash
tools/e2e_test.sh
```

The selftest pattern's bottom strip is a 16-bit binary frame counter (least significant bit on the
left). Photograph the Mac and the TV side by side and subtract the two numbers to get latency in frames.

## Android TV receiver (only for Google TV / Android TV / Fire TV sets)

Requirements: Android Studio (bundles the SDK, JDK 17 and Gradle). Not installed on this Mac yet.

1. Open `receiver-androidtv/` in Android Studio; let it sync and generate the Gradle wrapper.
2. On the TV: Settings → System → About → tap "Android TV OS build" 7× to unlock Developer options,
   then Developer options → enable **USB debugging** (and **Network debugging** / ADB over Wi-Fi if shown).
3. From the Mac: `adb connect <tv-ip>:5555` then **Run** in Android Studio, or
   `./gradlew installDebug` from `receiver-androidtv/`.
4. Launch "Mac TV Mirror" on the TV. It shows its IP and waits; it also advertises itself on Bonjour.

Then on the Mac: `mactv discover` → `mactv send --name "<the TV's name>"`.
