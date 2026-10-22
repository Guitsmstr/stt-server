#!/bin/sh
# Stage 3 checks — evidence for PROGRESO.md S3.1–S3.5.
#
# Requires: var/bin/stt (make), adapters (make), onnxruntime-dev, the model
# cache in var/models/moonshine-tiny (scripts/fetch-model.sh), jq, sox,
# python3. Runs take ~11 min wall: S3.1 feeds 5+ min of audio in real time
# (latency is only measurable at 1x), S3.4 runs 30 min of audio at 6x.
#
# Test audio: tests/assets/beckett.wav (real speech, Moonshine project, MIT).
# Reference transcript: "Ever tried ever failed, no matter try again, fail
# again, fail better." The stream assets repeat it with silence gaps.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
STT="$ROOT/var/bin/stt"
ADAPTER="$ROOT/adapters/moonshine/stt-adapter-moonshine"
MODEL="$ROOT/var/models/moonshine-tiny"
ECHO="$ROOT/adapters/echo/stt-adapter-echo"
WAV="$ROOT/tests/assets/beckett.wav"
TMP="$ROOT/var/tmp/stage3"
mkdir -p "$TMP"

fail() { echo "FAIL: $*" >&2; exit 1; }
need() { [ -e "$1" ] || fail "missing $1 (run: make / scripts/fetch-model.sh)"; }

need "$STT"; need "$ADAPTER"; need "$ECHO"; need "$WAV"
[ -d "$MODEL" ] || fail "model cache missing; run scripts/fetch-model.sh"

echo "== assets: build stream PCM files in var/tmp/stage3 =="
sox "$WAV" -t raw "$TMP/beckett.raw"
python3 - "$TMP/beckett.raw" "$TMP/stream5min.pcm" "$TMP/stream30min.pcm" "$TMP/silence_span.pcm" <<'EOF'
import sys
speech = open(sys.argv[1], "rb").read()
gaps = [0.3, 0.6, 0.9, 1.2, 0.5]  # deterministic pause cycle (s)
def stream(loops):
    parts = []
    for i in range(loops):
        parts.append(speech)
        parts.append(b"\x00" * int(32000 * gaps[i % len(gaps)]))
    return b"".join(parts)
five = stream(30)   # 30 x (9.96 + ~0.7) s ~= 320 s
thirty = stream(168)  # ~= 1791 s
open(sys.argv[2], "wb").write(five)
open(sys.argv[3], "wb").write(thirty)
sil = speech + b"\x00" * (32000 * 6) + speech  # 10 s speech, 6 s silence
open(sys.argv[4], "wb").write(sil)
print(f"stream5min.pcm: {len(five)/32000:.1f} s, stream30min.pcm: {len(thirty)/32000:.1f} s, silence_span.pcm: {len(sil)/32000:.1f} s")
EOF

echo
# S3.1 metric: per-repeat word coverage with tests/coverage.py. Each of the 30
# repeats of the reference clip is scored independently, so a segment that
# swallows a boundary cannot hide losses in the global score. Fuzzy matching
# absorbs the tiny model's normal spelling variance (fair/fail).
echo "== S3.1: 5 min continuous stream (real time) -> no relevant text loss =="
python3 tests/feed_stream.py --stt "$STT" --adapter "$ADAPTER" --model "$MODEL" \
	--pcm "$TMP/stream5min.pcm" --speed 1 --frame-ms 5000 --min-segment-ms 3000 \
	--report "$TMP/report-rt.json" > "$TMP/summary-rt.json"
cat "$TMP/summary-rt.json"
jq -e '.exit_code == 0' "$TMP/summary-rt.json" >/dev/null || fail "stt exited nonzero"
jq -e '.errors == []' "$TMP/summary-rt.json" >/dev/null || fail "stream reported errors: $(jq -c .errors "$TMP/summary-rt.json")"
audio=$(jq -r '.audio_s' "$TMP/summary-rt.json")
audio_s=${audio%.*}
[ "$audio_s" -ge 300 ] || fail "stream is only ${audio_s} s, need >= 300 s"
frames=$(jq -r '.eof.frames' "$TMP/summary-rt.json")
finals=$(jq -r '.finals' "$TMP/summary-rt.json")
[ "$frames" = "$finals" ] || fail "eof.frames ($frames) != finals ($finals)"
echo "finals: $finals, eof: $(jq -c .eof "$TMP/summary-rt.json")"
cov_rt=$(python3 tests/coverage.py "$TMP/report-rt.json")
echo "$cov_rt"
python3 tests/coverage.py "$TMP/report-rt.json" --threshold 90 >/dev/null || fail "per-repeat coverage below 90% (S3.1)"
echo "OK S3.1"

echo
echo "== S3.2: latency <= 800 ms from segment end to event (same real-time run) =="
# Metric: arrival on stdout minus the event's audio end (t1), per final.
# Steady state starts after --warmup-s 5 s: the first event also pays the
# adapter's model load (the nucleus buffers audio while the adapter starts).
# A per-2s-grid metric would charge batching itself against latency: audio
# inside a segment always waits for the segment to close, by design.
lat=$(jq -r '.latency_steady_max_s' "$TMP/summary-rt.json")
p95=$(jq -r '.latency_steady_p95_s' "$TMP/summary-rt.json")
avg=$(jq -r '.latency_steady_avg_s' "$TMP/summary-rt.json")
startup=$(jq -r '.latency_final_max_s' "$TMP/summary-rt.json")
awk -v a="$lat" 'BEGIN{exit !(a<=0.8)}' || fail "steady-state max final latency ${lat}s > 0.8s"
echo "steady final latency: max ${lat}s, p95 ${p95}s, avg ${avg}s (all-run max incl. startup: ${startup}s; $finals finals)"
echo "OK S3.2"

echo
echo "== S3.2b (O2 comparison): same audio, VAD off, 4x (text quality baseline) =="
python3 tests/feed_stream.py --stt "$STT" --adapter "$ADAPTER" --model "$MODEL" \
	--pcm "$TMP/stream5min.pcm" --speed 4 --frame-ms 5000 --min-segment-ms 3000 --vad=false \
	--report "$TMP/report-novad.json" > "$TMP/summary-novad.json"
cov_vad=$(python3 tests/coverage.py "$TMP/report-rt.json")
cov_novad=$(python3 tests/coverage.py "$TMP/report-novad.json")
echo "VAD $cov_vad vs no-VAD $cov_novad"
echo "OK S3.2b (evidence for bitacora)"

echo
echo "== S3.3: 6 s sustained silence emits no text =="
python3 tests/feed_stream.py --stt "$STT" --adapter "$ADAPTER" --model "$MODEL" \
	--pcm "$TMP/silence_span.pcm" --speed 4 --frame-ms 5000 --min-segment-ms 3000 \
	--report "$TMP/report-s33.json" > "$TMP/summary-s33.json"
cat "$TMP/summary-s33.json"
# No final may lie entirely inside the silent span [9.96, 15.96] s.
inside=$(jq '[.finals[] | select(.t0 >= 9.96 and .t1 <= 15.96)] | length' "$TMP/report-s33.json")
[ "$inside" -eq 0 ] || fail "$inside finals inside the silence span (junk text)"
skipped=$(jq -r '.eof.skipped_s' "$TMP/summary-s33.json")
awk -v s="$skipped" 'BEGIN{exit !(s>=5.0)}' || fail "VAD skipped only ${skipped}s of the 6s silence"
before=$(jq '[.finals[] | select(.t1 <= 10.2 and (.text | test("ever"; "i")))] | length' "$TMP/report-s33.json")
[ "$before" -ge 1 ] || fail "speech before the silence was not transcribed"
echo "finals inside silence: 0, skipped_s: $skipped, speech before silence: $before finals"
echo "OK S3.3"

echo
echo "== S3.4: 30 min stream at 6x: RSS stable, no frames lost =="
python3 tests/feed_stream.py --stt "$STT" --adapter "$ADAPTER" --model "$MODEL" \
	--pcm "$TMP/stream30min.pcm" --speed 6 --frame-ms 5000 --min-segment-ms 3000 \
	--report "$TMP/report-30min.json" > "$TMP/summary-30min.json"
cat "$TMP/summary-30min.json"
jq -e '.exit_code == 0 and .errors == []' "$TMP/summary-30min.json" >/dev/null || fail "errors during 30 min stream"
audio=$(jq -r '.audio_s' "$TMP/summary-30min.json"); audio_s=${audio%.*}
[ "$audio_s" -ge 1780 ] || fail "stream only ${audio_s} s"
frames=$(jq -r '.eof.frames' "$TMP/summary-30min.json")
finals=$(jq -r '.finals' "$TMP/summary-30min.json")
[ "$frames" = "$finals" ] || fail "frames ($frames) != finals ($finals): lost frames"
rssmax=$(jq -r '.nucleus_rss_max_kb' "$TMP/summary-30min.json")
rssq1=$(jq -r '.nucleus_rss_first_quarter_max_kb' "$TMP/summary-30min.json")
rssq4=$(jq -r '.nucleus_rss_last_quarter_max_kb' "$TMP/summary-30min.json")
drift=$((rssq4 - rssq1))
[ "$rssmax" -lt 65536 ] || fail "nucleus RSS ${rssmax} kB >= 64 MB"
[ "$drift" -lt 10240 ] || fail "nucleus RSS drift ${drift} kB suggests a leak"
adrss=$(jq -r '.eof.rss_kb // 0' "$TMP/summary-30min.json")
[ "$adrss" -gt 0 ] && [ "$adrss" -lt 300000 ] || fail "adapter RSS ${adrss} kB out of range"
echo "nucleus RSS: max ${rssmax} kB, drift ${drift} kB; adapter peak: ${adrss} kB; frames: $frames"
echo "OK S3.4"

echo
echo "== S3.5: partial events according to config =="
out=$(STT_ECHO_PARTIALS=1 "$STT" stream --adapter "$ECHO" --partials=true --vad=false < "$TMP/beckett.raw")
n=$(echo "$out" | jq -s '[.[] | select(.type=="partial")] | length')
f=$(echo "$out" | jq -s '[.[] | select(.type=="final")] | length')
[ "$n" -eq "$f" ] && [ "$n" -ge 1 ] || fail "partials=true: expected $f partials, got $n"
echo "partials=true (echo): $n partials / $f finals"

out=$(STT_ECHO_PARTIALS=1 "$STT" stream --adapter "$ECHO" --vad=false < "$TMP/beckett.raw")
n=$(echo "$out" | jq -s '[.[] | select(.type=="partial")] | length')
[ "$n" -eq 0 ] || fail "partials=false (default): $n partials leaked"
echo "partials=false (default): 0 partials"

out=$("$STT" stream --adapter "$ADAPTER" --model "$MODEL" --partials=true --vad=false < "$TMP/beckett.raw")
n=$(echo "$out" | jq -s '[.[] | select(.type=="partial")] | length')
[ "$n" -eq 0 ] || fail "moonshine emitted partials without declaring the capability"
echo "partials=true + moonshine (capability ['final'] only): 0 partials (expected; justification in PROGRESO)"
echo "OK S3.5"

rm -f "$TMP/stream5min.pcm" "$TMP/stream30min.pcm" "$TMP/silence_span.pcm" "$TMP/beckett.raw"
echo
echo "Stage 3 checks: ALL OK"
