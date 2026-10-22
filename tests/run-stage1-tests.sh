#!/bin/sh
# Stage 1 smoke tests — evidence for PROGRESO.md checks S1.2 and S1.4.
# Requires: var/bin/stt, adapters/echo/stt-adapter-echo, jq, sox.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STT="$ROOT/var/bin/stt"
ADAPTER="$ROOT/adapters/echo/stt-adapter-echo"
TMP="$ROOT/var/tmp"
mkdir -p "$TMP"

echo "== S1.2: stt stream + echo adapter, NDJSON validated with jq =="
head -c 64000 /dev/zero > "$TMP/pcm.raw"   # 2 s of audio (32 KB/s)
out=$("$STT" stream --adapter "$ADAPTER" --frame-ms 500 < "$TMP/pcm.raw")
echo "$out"
echo "$out" | jq -e -c 'select(.type=="start")' >/dev/null
echo "$out" | jq -e -c 'select(.type=="final")' >/dev/null
echo "$out" | jq -e -c 'select(.type=="eof")' >/dev/null
finals=$(echo "$out" | jq -s '[.[] | select(.type=="final")] | length')
[ "$finals" -eq 4 ] || { echo "FAIL: 4 finals expected, got $finals"; exit 1; }
echo "$out" | jq -e -c 'select(.type=="eof") | .frames == 4' | grep -q true
echo "OK S1.2: NDJSON valido, 4 frames -> 4 finals"

echo "== S1.2b: stt once (WAV) =="
sox -n -r 16000 -c 1 -b 16 "$TMP/t.wav" synth 1 sine 440
out=$("$STT" once --adapter "$ADAPTER" --frame-ms 500 "$TMP/t.wav")
echo "$out" | jq -e -c 'select(.type=="eof")' >/dev/null
echo "OK S1.2b: wav one-shot"

echo "== S1.4: adapter crash -> restart =="
head -c 160000 /dev/zero > "$TMP/pcm2.raw"   # 5 s = 10 frames de 500 ms
out=$(STT_ECHO_CRASH_AFTER=2 "$STT" stream --adapter "$ADAPTER" --max-restarts 5 --frame-ms 500 < "$TMP/pcm2.raw")
echo "$out"
echo "$out" | jq -e -c 'select(.type=="error" and .code=="adapter_crash" and (.fatal|not))' >/dev/null
echo "$out" | jq -e -c 'select(.type=="eof")' >/dev/null
echo "OK S1.4: reinicio reportado y pipeline completo"

echo
echo "Stage 1 smoke tests: ALL OK"
