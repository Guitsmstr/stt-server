#!/bin/sh
# Stage 5 checks (partial smoke) — S5.3/S5.6 only.
#
# Full Stage 5 checks are still pending:
#   S5.4 fuzzy ES/EN coverage, S5.5 formal RTF/RSS with 5 s frames,
#   S5.7 engine-selection regression (stages 1-4), S5.8 --out fan-out,
#   S5.9 karaoke/partials demo.
#
# This script proves the sherpa adapter loads both cached models and that
# final + partial events flow through the nucleus. It is intentionally short
# (~30 s with warm model cache) and must not be read as closing Stage 5.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
STT="$ROOT/var/bin/stt"
ADAPTER="$ROOT/adapters/sherpa/stt-adapter-sherpa"
EN="$ROOT/var/models/sherpa-zipformer-en-kroko"
ES="$ROOT/var/models/sherpa-zipformer-es"
WAV="$ROOT/tests/assets/beckett.wav"
TMP="$ROOT/var/tmp/stage5"
mkdir -p "$TMP"

fail() { echo "FAIL: $*" >&2; exit 1; }
need() { [ -e "$1" ] || fail "missing $1 (run: make / make models)"; }

need "$STT"; need "$ADAPTER"; need "$WAV"
[ -d "$EN" ] || fail "missing $EN (run: scripts/fetch-model.sh --model kroko-en)"
[ -d "$ES" ] || fail "missing $ES (run: scripts/fetch-model.sh --model kroko-es)"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v sox >/dev/null 2>&1 || fail "sox not found"

echo "== S5.3/S5.6: sherpa EN one-shot with partials =="
timeout 180 "$STT" once --adapter "$ADAPTER" --model "$EN" --partials "$WAV" \
    >"$TMP/en.ndjson" 2>"$TMP/en.err" || fail "stt once (EN) failed; see $TMP/en.err"
jq -e 'select(.type == "partial")' "$TMP/en.ndjson" >/dev/null \
    || fail "no partial events (capability partial not wired)"
text=$(jq -r 'select(.type == "final") | .text' "$TMP/en.ndjson" | tr '\n' ' ')
printf '%s' "$text" | grep -qi 'ever tried' || fail "unexpected EN text: $text"
printf '%s' "$text" | grep -qi 'fail better' || fail "tail missing in EN text: $text"
echo "OK EN: $(printf '%s' "$text" | sed 's/  */ /g')"

echo "== S5.3/S5.6: sherpa ES model loads and transcribes its bundled clip =="
CLIP="$ES/test_wav0.wav"
[ -f "$CLIP" ] || fail "missing $CLIP"
# The bundled clip is 22.05 kHz; the contract is 16 kHz and the adapter
# resamples model-rate features internally, so feed a 16 kHz copy.
sox "$CLIP" -r 16000 -c 1 -b 16 "$TMP/es16k.wav" 2>/dev/null \
    || fail "sox could not resample $CLIP"
timeout 240 "$STT" once --adapter "$ADAPTER" --model "$ES" "$TMP/es16k.wav" \
    >"$TMP/es.ndjson" 2>"$TMP/es.err" || fail "stt once (ES) failed; see $TMP/es.err"
text=$(jq -r 'select(.type == "final") | .text' "$TMP/es.ndjson" | tr '\n' ' ')
[ -n "$(printf '%s' "$text" | tr -d '[:space:]')" ] || fail "empty ES transcription"
echo "OK ES: $(printf '%s' "$text" | sed 's/  */ /g')"

echo
echo "Stage 5 partial smoke: OK"
echo "PENDING: S5.4 (fuzzy ES/EN), S5.5 (RTF/RSS 5 s), S5.7 (regression), S5.8 (--out), S5.9 (karaoke)"
