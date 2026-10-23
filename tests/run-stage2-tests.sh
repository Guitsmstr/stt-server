#!/bin/sh
# Stage 2 checks — evidence for PROGRESO.md S2.1–S2.5.
#
# Requires: var/bin/stt (make core), onnxruntime-dev, jq, and the model cache
# in var/models/moonshine-tiny (scripts/fetch-model.sh).
#
# Test audio: tests/assets/beckett.wav — real speech sample distributed with
# the Moonshine project (moonshine-ai/moonshine, MIT). Reference transcript:
# "Ever tried ever failed, no matter try again, fail again, fail better."
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
STT="$ROOT/var/bin/stt"
ADAPTER="$ROOT/adapters/moonshine/stt-adapter-moonshine"
MODEL="$ROOT/var/models/moonshine-tiny"
WAV="$ROOT/tests/assets/beckett.wav"
TMP="$ROOT/var/tmp"
mkdir -p "$TMP"

fail() { echo "FAIL: $*" >&2; exit 1; }
need() { [ -e "$1" ] || fail "missing $1 (run: make core / scripts/fetch-model.sh)"; }

need "$STT"; need "$WAV"
[ -d "$MODEL" ] || fail "model cache missing; run scripts/fetch-model.sh"

echo "== S2.1: adapter builds against system libonnxruntime =="
make -C "$ROOT/adapters/moonshine" clean all >/dev/null
ldd "$ADAPTER" | grep -q 'libonnxruntime\.so' || fail "adapter is not linked to libonnxruntime"
echo "linked: $(ldd "$ADAPTER" | grep libonnxruntime | tr -s ' ')"
echo "OK S2.1"

echo "== S2.2: transcribe test file -> valid NDJSON + coherent text =="
out=$("$STT" once --adapter "$ADAPTER" --model "$MODEL" --frame-ms 10000 "$WAV")
echo "$out"
echo "$out" | jq -e -c 'select(.type=="start")' >/dev/null
echo "$out" | jq -e -c 'select(.type=="final")' >/dev/null
echo "$out" | jq -e -c 'select(.type=="eof")' >/dev/null
# Stage 3 note: with VAD segmentation the transcript may span several finals;
# join them before matching (same intent: coherent end-to-end transcription).
echo "$out" | jq -e -c 'select(.type=="final") | .text' >/dev/null
transcript=$(echo "$out" | jq -r 'select(.type=="final") | .text' | tr '\n' ' ')
echo "$transcript" | grep -Eiq 'ever tried.*fail +better' \
    || fail "transcription not coherent: $transcript"
echo "OK S2.2: $(echo "$out" | jq -r 'select(.type=="final") | .text')"

echo "== S2.3: RTF <= 0.35 (10 s frame and 2 s frames) =="
rtf=$(echo "$out" | jq -r 'select(.type=="final") | .rtf')
ok=$(awk -v r="$rtf" 'BEGIN{print (r<=0.35)?"yes":"no"}')
[ "$ok" = yes ] || fail "10 s frame RTF $rtf > 0.35"
echo "10 s frame: rtf=$rtf"

# --vad=false keeps the check's stated 2 s frames: with Stage 3 VAD enabled the
# segmenter sends 0.7-1.3 s segments and per-frame overhead inflates RTF.
out2=$("$STT" once --adapter "$ADAPTER" --model "$MODEL" --vad=false --frame-ms 2000 "$WAV")
echo "$out2" | jq -c 'select(.type=="final") | {frame,rtf,text}'
worst=$(echo "$out2" | jq -s '[.[] | select(.type=="final") | .rtf] | max')
ok=$(awk -v r="$worst" 'BEGIN{print (r<=0.35)?"yes":"no"}')
[ "$ok" = yes ] || fail "2 s frame worst RTF $worst > 0.35"
echo "OK S2.3: worst 2 s frame rtf=$worst"

echo "== S2.4: adapter peak RSS < 300 MB =="
rss=$(echo "$out" | jq -r 'select(.type=="eof") | .rss_kb')
[ -n "$rss" ] && [ "$rss" != null ] || fail "adapter did not report rss_kb"
[ "$rss" -lt 300000 ] || fail "adapter peak RSS ${rss} kB >= 300000 kB"
echo "OK S2.4: adapter peak RSS ${rss} kB ($(awk -v r="$rss" 'BEGIN{printf "%.1f", r/1024}') MiB)"

echo "== S2.5: model cache is idempotent offline =="
"$ROOT/scripts/fetch-model.sh" --offline >"$TMP/fetch1.txt"
"$ROOT/scripts/fetch-model.sh" --offline >"$TMP/fetch2.txt"
grep -q '^download:' "$TMP/fetch1.txt" && fail "first offline run tried to download"
[ "$(grep -c '^cached:' "$TMP/fetch1.txt")" -eq 4 ] || fail "unexpected offline fetch output"
cmp -s "$TMP/fetch1.txt" "$TMP/fetch2.txt" || fail "fetch-model outputs differ between runs"
[ "$(wc -l < "$MODEL/vocab.tsv" | tr -d ' ')" -eq 32000 ] || fail "vocab.tsv is not complete"
echo "OK S2.5: second run without network, 4/4 files cached"

echo "== extra: unsupported audio format is rejected (fatal, no restart loop) =="
if errout=$("$STT" stream --adapter "$ADAPTER" --model "$MODEL" --channels 2 < /dev/null 2>/dev/null); then
    fail "stereo input was accepted"
fi
echo "$errout" | jq -e -c 'select(.type=="error" and .code=="adapter_dead" and .fatal==true)' >/dev/null \
    || fail "expected one fatal adapter_dead error, got: $errout"
echo "OK extra: stereo rejected with fatal error"

echo
echo "Stage 2 checks: ALL OK"
