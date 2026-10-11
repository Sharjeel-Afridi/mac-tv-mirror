# mactv wire protocol v1

One TCP connection from the Mac (sender) to the TV (receiver), default port **7000**.
The receiver advertises itself over Bonjour / NSD as **`_mactvmirror._tcp`**.

All integers are **big-endian** (network order).

## Message framing

```
offset  size  field
0       1     type        (see table)
1       1     flags       bit 0 = keyframe (VIDEO_FRAME only)
2       2     reserved    (0)
4       8     pts_us      presentation timestamp, microseconds, sender clock
12      4     length      payload length in bytes
16      n     payload
```

## Message types

| type | name              | direction | payload |
|------|-------------------|-----------|---------|
| 0x01 | HELLO             | Mac → TV  | UTF-8 JSON `{"v":1,"name":"...","width":W,"height":H,"fps":F,"codec":"h264"}` |
| 0x02 | VIDEO_CONFIG      | Mac → TV  | Annex-B SPS + PPS (`00 00 00 01 SPS 00 00 00 01 PPS`). Sent before the first keyframe and whenever parameter sets change. |
| 0x03 | VIDEO_FRAME       | Mac → TV  | One Annex-B access unit. Keyframes additionally carry SPS/PPS in-band and set flag bit 0. |
| 0x04 | AUDIO_CONFIG      | Mac → TV  | *(reserved, phase 4)* `u32 sampleRate, u8 channels, AudioSpecificConfig...` |
| 0x05 | AUDIO_FRAME       | Mac → TV  | *(reserved, phase 4)* one raw AAC frame |
| 0x10 | HELLO_ACK         | TV → Mac  | UTF-8 JSON `{"v":1,"name":"...","maxWidth":W,"maxHeight":H}` |
| 0x11 | REQUEST_KEYFRAME  | TV → Mac  | empty. Receiver fell behind or just (re)started its decoder. |

## Sequence

```
Mac                                   TV
 | ---- HELLO ----------------------> |
 | <--- HELLO_ACK ------------------- |
 | ---- VIDEO_CONFIG ---------------> |   decoder configured with csd-0/csd-1
 | ---- VIDEO_FRAME (key) ----------> |
 | ---- VIDEO_FRAME ----------------> |  ...
 | <--- REQUEST_KEYFRAME ------------ |   (TV dropped frames, wants a clean resync)
 | ---- VIDEO_FRAME (key) ----------> |
```

## Rules

- The sender's first VIDEO_FRAME after connecting is always a keyframe.
- A receiver ignores non-keyframes until it has seen a keyframe (start-up and after any drop).
- Either side may close the socket; the receiver goes back to "waiting" and keeps advertising.
- Max payload 16 MiB; anything larger is a protocol error and the connection is dropped.
