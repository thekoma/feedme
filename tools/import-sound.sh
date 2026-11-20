#!/bin/bash
# Turn any audio file into a bundled feedme sound: mono, 22050 Hz, 16-bit WAV,
# trimmed, with short fades and the same loudness as the other bundled sounds.
#
#   tools/import-sound.sh <input> <output.wav> [start-seconds] [duration-seconds]
#
# Needs ffmpeg. Loudness is normalised in two passes to TARGET_LUFS; clips too
# short to measure (under ~0.4 s) are peak-normalised instead.

set -euo pipefail

TARGET_LUFS=-20
TARGET_PEAK=-1.5
SAMPLE_RATE=22050
FADE_IN=0.02
FADE_OUT=0.15

if [ $# -lt 2 ]; then
  echo "usage: $0 <input> <output.wav> [start-seconds] [duration-seconds]" >&2
  exit 2
fi
input="$1" output="$2"
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg not found: install it first (macOS: brew install ffmpeg, Debian/Ubuntu: apt install ffmpeg)." >&2
  exit 1
fi
if [ ! -r "$input" ]; then
  echo "cannot read '$input'." >&2
  exit 1
fi
trim=()
[ -n "${3:-}" ] && trim+=(-ss "$3")
[ -n "${4:-}" ] && trim+=(-t "$4")

# Fade out without knowing the length: reverse, fade in, reverse back.
shape="aformat=channel_layouts=mono,afade=t=in:d=$FADE_IN,areverse,afade=t=in:d=$FADE_OUT,areverse"

if ! measure="$(ffmpeg -hide_banner -nostats ${trim[@]+"${trim[@]}"} -i "$input" \
  -af "$shape,loudnorm=I=$TARGET_LUFS:TP=$TARGET_PEAK:print_format=summary" -f null - 2>&1)"; then
  printf 'ffmpeg could not read %s:\n%s\n' "$input" "$measure" >&2
  exit 1
fi
field() { printf '%s\n' "$measure" | sed -n "s/^$1:[[:space:]]*\([-0-9.inf+]*\).*/\1/p" | head -n 1; }
input_i="$(field 'Input Integrated')"
input_tp="$(field 'Input True Peak')"
input_lra="$(field 'Input LRA')"
input_thresh="$(field 'Input Threshold')"

case "$input_i" in
  '' | *inf* | -70.0)
    peak="$(ffmpeg -hide_banner -nostats ${trim[@]+"${trim[@]}"} -i "$input" -af "$shape,volumedetect" -f null - 2>&1 \
      | sed -n 's/.*max_volume: \([-0-9.]*\) dB.*/\1/p')"
    gain="$(awk -v p="$peak" -v t="$TARGET_PEAK" 'BEGIN { printf "%.2f", t - p - 4 }')"
    normalise="volume=${gain}dB"
    ;;
  *)
    normalise="loudnorm=I=$TARGET_LUFS:TP=$TARGET_PEAK:measured_I=$input_i:measured_TP=$input_tp:measured_LRA=$input_lra:measured_thresh=$input_thresh:linear=true"
    ;;
esac

ffmpeg -hide_banner -loglevel error -y ${trim[@]+"${trim[@]}"} -i "$input" \
  -af "$shape,$normalise" -ac 1 -ar "$SAMPLE_RATE" -c:a pcm_s16le "$output"
echo "$output"
