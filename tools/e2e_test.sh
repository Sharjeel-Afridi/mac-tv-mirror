#!/bin/bash
# End-to-end check without a TV: fake receiver advertises on Bonjour, the sender finds it by name,
# streams the synthetic pattern, and ffprobe validates what arrived.
#
#   tools/e2e_test.sh            # builds the sender first, then runs ~5 s
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/sender-macos/.build/release/mactv"
WORK="${TMPDIR:-/tmp}/mactv-e2e.$$"
mkdir -p "$WORK"
trap 'kill $RPID $SPID 2>/dev/null || true; rm -rf "$WORK"' EXIT

echo "• building sender"
(cd "$ROOT/sender-macos" && swift build -c release 2>&1 | grep -E "error|Build complete" || true)

echo "• starting fake receiver (Bonjour name \"E2E TV\")"
python3 "$ROOT/tools/fake_receiver.py" --advertise --name "E2E TV" --out "$WORK/stream.h264" \
    --exit-after-frames 150 --keyframe-every 2 > "$WORK/receiver.log" 2>&1 &
RPID=$!
sleep 1.5

echo "• streaming selftest pattern by name"
"$BIN" selftest --name "E2E TV" > "$WORK/sender.log" 2>&1 &
SPID=$!
wait $RPID || true
sleep 1
kill $SPID 2>/dev/null || true

echo "• receiver saw:"; grep -E "HELLO|session|wrote" "$WORK/receiver.log" | sed 's/^/    /'
echo "• sender saw:";   grep -E "connected|requested|encoded" "$WORK/sender.log" | sed 's/^/    /'

echo "• ffprobe:"
ffprobe -v error -count_frames -show_entries stream=codec_name,profile,width,height,nb_read_frames \
    -of default=nw=1 "$WORK/stream.h264" | sed 's/^/    /'
FRAMES=$(ffprobe -v error -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$WORK/stream.h264")
KEYS=$(ffprobe -v error -select_streams v -show_entries frame=key_frame -of csv=p=0 "$WORK/stream.h264" | grep -c '^1' || true)
echo "    keyframes=$KEYS"
if [ "$FRAMES" -ge 140 ] && [ "$KEYS" -ge 3 ]; then
    echo "PASS: $FRAMES frames decoded, $KEYS keyframes (initial + requested)"
else
    echo "FAIL: expected ≥140 frames and ≥3 keyframes, got $FRAMES / $KEYS"
    exit 1
fi
