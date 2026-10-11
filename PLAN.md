# Mac → TCL TV screen mirroring — plan

**Goal:** stream the MacBook's screen to the TCL TV over Wi-Fi with the lowest latency the TV allows,
using our own software on the Mac. No Cast, no AirPlay, no licensed protocols.

## What the TV turned out to be (2026-10-11)

Probed on the LAN: the TV answers SSDP as **"TCL Smart TV" / "TCL Media Renderer"** on a Linux 3.10
kernel with libupnp 1.6.22, exposing a UPnP **MediaRenderer** (AVTransport, ConnectionManager,
RenderingControl) on port 49153. It does **not** advertise Chromecast built-in, the Android TV remote
service, ADB, AirPlay, or Roku's ECP. T-Cast is TCL's companion app for exactly this Linux platform.

Consequence: **it is not Android/Google TV**, so the Android receiver app (`receiver-androidtv/`)
cannot be installed on it. That code is parked, not deleted; it is the right path for any Google TV.

The TV's `GetProtocolInfo` lists H.264 + AAC in MPEG-TS (`video/mpeg`, profile `AVC_TS_MP_HD_AAC_ISO`)
and the same in MP4, among 177 entries. Its player identifies as `QtEmbedded; Linux ... AppleWebKit/537.4`.

## Architecture (DLNA path)

```
MacBook (sender)                                            TCL TV (Linux, UPnP MediaRenderer)
┌────────────────────────────────────────────┐             ┌───────────────────────────────────┐
│ capture → H.264 (+AAC) → MPEG-TS           │   HTTP GET  │ built-in DLNA player pulls         │
│ tiny HTTP server:  http://mac:8090/live.ts │ ◀────────── │ http://mac:8090/live.ts            │
│ UPnP control point: SSDP discover, then    │   SOAP      │ AVTransport: SetAVTransportURI,    │
│ SetAVTransportURI + Play / Stop            │ ──────────▶ │ Play, Stop, GetTransportInfo       │
└────────────────────────────────────────────┘             └───────────────────────────────────┘
```

The TV is a pull client: the Mac just has to serve a live, never-ending transport stream and tell
the TV to play the URL. Latency is set by the TV player's input buffer, which we cannot control
from outside; expect roughly 1–3 s. Knobs on our side: keyframe every second, no B-frames, small
PES packets, no mux delay.

## Phases

- [x] **Phase 0 — scaffolding.** PLAN.md, PROTOCOL.md, README.md.
- [x] **Phase 1 — Mac capture/encode pipeline.** `sender-macos/` (`mactv`): ScreenCaptureKit →
      VideoToolbox H.264 low-latency → Annex-B. Verified with `selftest` + `tools/fake_receiver.py`
      + ffprobe (`tools/e2e_test.sh`). Reused as-is by Phase 3.
- [x] **Phase 2 — Android TV receiver.** Written, not buildable here (no SDK), and **not applicable
      to this TV**. Parked.
- [x] **Phase 2b — identify the TV and prove the DLNA path.** `tools/dlna_push.py`: SSDP discovery,
      UPnP control point, live MPEG-TS over HTTP fed by ffmpeg. **Pushed a 25 s test pattern to the
      real TV: transport state PLAYING / OK for the whole run, TV pulled the stream continuously.**
      (Picture not visually confirmed from here; the TV's own state machine says it played.)
- [ ] **Phase 3 — mirror the real screen via DLNA.** Two steps:
      1. *Today, with ffmpeg:* `python3 tools/dlna_push.py --source screen` from Terminal (needs
         Screen Recording permission for Terminal). Measure latency with a stopwatch on the Mac.
      2. *Native:* add `mactv cast` to the Swift sender — SSDP + SOAP control point, an MPEG-TS
         muxer (PAT/PMT/PES/PCR, H.264 ES in, ~300 lines), and an HTTP server on NWListener —
         reusing `ScreenCapturer` and `H264Encoder`. Removes the ffmpeg dependency and lets us tune
         the stream for the TV's player.
- [~] **Phase 4 — audio.** *ffmpeg path (done):* `dlna_push.py` captures the Mac's output through a
      loopback device (AirBeamTV Audio is already installed; BlackHole works too) and muxes AAC into
      the TS. The user sets the Mac's sound output to that device. *Native path (todo):* ScreenCaptureKit
      system audio → AudioToolbox AAC → second TS elementary stream, no loopback driver needed.
- [ ] **Phase 5 — polish.** Menubar app, pick display, auto-reconnect if the TV drops the stream,
      bitrate presets, remember the TV.

## Decisions and why

- **DLNA over trying to speak T-Cast.** T-Cast's phone-mirroring protocol is undocumented and would
  need reverse engineering of the iOS/Android app; DLNA is already on the TV and worked first try.
- **MPEG-TS over HTTP, not HLS or MP4.** The TV lists TS profiles explicitly and a single endless
  HTTP response is the simplest live transport; HLS adds segment latency and this player may not
  support it for DLNA items.
- **Claim `DLNA.ORG_PN=AVC_TS_MP_HD_AAC_ISO`** with `DLNA.ORG_OP=00` (no seek) and the live
  `DLNA.ORG_FLAGS`, in both the DIDL-Lite metadata and the `contentFeatures.dlna.org` header.
- **Keep the Android path.** Same encoder and framing; it is the low-latency answer for a Google TV.

## Status log

- 2026-10-11 — Phases 0–1 done and verified locally. Phase 2 written but parked: LAN probe shows the
  TV is TCL's Linux platform (UPnP MediaRenderer, no Android services). Phase 2b: `dlna_push.py`
  pushed a test pattern to the TV, state PLAYING/OK for 25 s, then Stop. Next: user runs
  `--source screen` from Terminal, confirms the picture and reports latency; then native `mactv cast`.
- 2026-10-11 (later) — User measured ~5 s latency with the first DLNA prototype. Server-side buffer probe
  (`tools/tv_buffer_probe.py`, 2 vs 12 Mbit/s CBR files): the TV reports PLAYING after taking ~2.0–2.4 MB
  regardless of bitrate, i.e. a **byte-based pre-buffer of ~2 MB**, and its intake tops out at ~9.7 Mbit/s
  (Wi-Fi link). So latency ≈ 2 MB ÷ stream bitrate: ~5 s at 3 Mbit/s, ~2 s at 7 Mbit/s. `dlna_push.py` now
  pads to 7 Mbit/s CBR by default and ships bytes without batching (os.read, TCP_NODELAY, small PES,
  flush_packets). Expected floor over Wi-Fi: ~2 s. Lower needs a faster link to the TV (Ethernet, then
  raise --muxrate) or a different transport than the TV's DLNA player.

- 2026-10-11 (audio) — Added loopback-device audio capture to `dlna_push.py` (auto-detects AirBeamTV Audio /
  BlackHole). Not verifiable from the sandbox: Microphone permission is not granted to the Claude app.
