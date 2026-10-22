#!/bin/sh
# Stage 4 checks — real microphone input (S4.1–S4.4) + fast regressions.
#
# Run inside the Alpine chroot as root, after scripts/termux-mic-setup.sh.
# The live tests use Android TTS as a reproducible voice source played through
# the phone speaker and captured by the phone microphone.
#
#   sh tests/run-stage4-tests.sh
#
# Evidence is written to var/tmp/stage4/.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
STT="$ROOT/var/bin/stt"
ADAPTER="$ROOT/adapters/moonshine/stt-adapter-moonshine"
MODEL="$ROOT/var/models/moonshine-tiny"
ECHO="$ROOT/adapters/echo/stt-adapter-echo"
CAPTURE="$ROOT/scripts/termux-capture.sh"
SPEAK="$ROOT/scripts/termux-speak.sh"
PROBE="$ROOT/tests/live_probe.py"
ENVFILE="$ROOT/var/bin/termux-mic.env"
TMP="$ROOT/var/tmp/stage4"
mkdir -p "$TMP"
LOG="$TMP/stage4-run.log"

fail() { echo "FAIL: $*" >&2; exit 1; }
need() { [ -e "$1" ] || fail "missing $1"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }
say() { echo "$*" | tee -a "$LOG"; }

need "$STT"; need "$ADAPTER"; need "$ECHO"; need "$CAPTURE"; need "$SPEAK"; need "$PROBE"
[ -f "$ENVFILE" ] || fail "missing $ENVFILE; run: sh scripts/termux-mic-setup.sh"
need_cmd nsenter; need_cmd jq; need_cmd python3; need_cmd sox

: > "$LOG"

# ---- Android helpers -------------------------------------------------------
android_shell() {
    nsenter -t 1 -m -p -- /system/bin/runcon u:r:shell:s0 /system/bin/sh -c "$*"
}

get_volume() {
    android_shell "settings get system volume_music_speaker" 2>/dev/null | tr -d '\r\n '
}
set_volume() {
    android_shell "cmd media_session volume --stream 3 --set $1" >/dev/null 2>&1 || true
}

VOLUME_ORIG=$(get_volume)
case "$VOLUME_ORIG" in ''|null) VOLUME_ORIG=0 ;; esac
VOLUME_CHANGED=0
cleanup() {
    if [ "$VOLUME_CHANGED" = 1 ]; then
        set_volume "$VOLUME_ORIG"
    fi
    # Never leave our capture servers behind (bracket trick: do not match
    # the pkill/pgrep command line itself).
    pkill -f "[s]ource_name=stt_mic_4713" 2>/dev/null || true
    pkill -f "[s]ource_name=stt_mic_4714" 2>/dev/null || true
    pkill -f "[s]ource_name=stt_mic_4723" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# The TTS tests need the media stream audible; restore the user's level on exit.
if [ "$VOLUME_ORIG" != 12 ]; then
    set_volume 12
    VOLUME_CHANGED=1
fi

say "== G1: build =="
make all >> "$LOG" 2>&1 || fail "make all failed (see $LOG)"
(cd core && go vet ./... >> "$LOG" 2>&1) || fail "go vet failed (see $LOG)"
say "build + go vet OK"

say
say "== G5a: Stage 1 (make test) =="
make test >> "$LOG" 2>&1 || fail "make test (Stage 1) failed (see $LOG)"
say "Stage 1 OK"

say
say "== G5b: Stage 2 (Moonshine checks) =="
sh tests/run-stage2-tests.sh >> "$LOG" 2>&1 || fail "Stage 2 checks failed (see $LOG)"
say "Stage 2 OK"

say
say "== G5c: Stage 3 smoke (VAD + Moonshine stream) =="
sox tests/assets/beckett.wav -t raw "$TMP/beckett.raw"
python3 tests/feed_stream.py --stt "$STT" --adapter "$ADAPTER" --model "$MODEL" \
    --pcm "$TMP/beckett.raw" --speed 4 --frame-ms 5000 --min-segment-ms 3000 \
    --report "$TMP/s3_smoke.json" > "$TMP/s3_smoke.summary.json" 2>> "$LOG"
jq -e '.exit_code == 0' "$TMP/s3_smoke.summary.json" >/dev/null || fail "Stage 3 smoke: stt exited nonzero"
jq -e '.finals >= 1' "$TMP/s3_smoke.summary.json" >/dev/null || fail "Stage 3 smoke: no finals"
say "Stage 3 smoke OK: $(jq -c '{finals,audio_s}' "$TMP/s3_smoke.summary.json")"

say
say "== S4.1: microphone -> PCM capture =="
CAP_RC=0
timeout 9 sh "$CAPTURE" --port 4713 > "$TMP/s41.raw" 2> "$TMP/s41.err" || CAP_RC=$?
SIZE=$(stat -c %s "$TMP/s41.raw" 2>/dev/null || echo 0)
[ "$SIZE" -gt 100000 ] || fail "S4.1: captured only $SIZE bytes (rc=$CAP_RC); see $TMP/s41.err"
python3 - "$TMP/s41.raw" > "$TMP/s41_check.txt" 2>&1 <<'PY' || fail "S4.1: captured audio check failed (see $TMP/s41_check.txt)"
import struct, sys
d = open(sys.argv[1], "rb").read()
n = len(d) // 2
s = struct.unpack("<%dh" % n, d[:n*2]) if n else ()
rms = (sum(x*x for x in s) / n) ** 0.5 if n else 0
peak = max(abs(x) for x in s) if s else 0
print("capture: %.2f s, rms=%.1f peak=%d" % (n/16000, rms, peak))
assert rms > 20, "microphone capture looks silent (rms %.1f)" % rms
assert peak > 100, "microphone capture has no signal"
PY
cat "$TMP/s41_check.txt" | tee -a "$LOG"
"$STT" stream --adapter "$ADAPTER" --model "$MODEL" < "$TMP/s41.raw" \
    > "$TMP/s41.ndjson" 2> "$TMP/s41.stt.err" || fail "S4.1: stt failed on captured PCM"
grep -q '"type":"eof"' "$TMP/s41.ndjson" || fail "S4.1: no eof in captured-PCM run"
say "S4.1 OK: $(stat -c %s "$TMP/s41.raw") bytes, eof present"

say
say "== S4.2/S4.3: live TTS voice -> text, latency <= 3 s =="
# A previous interrupted termux-tts-speak can leave the Termux:API service
# waiting forever; restarting it is cheap and does not touch permissions.
android_shell "am force-stop com.termux.api; am startservice -n com.termux.api/.KeepAliveService" >/dev/null 2>&1 || true
sleep 2
timeout 50 python3 "$PROBE" \
    --capture "$CAPTURE" --capture-args "--port 4714" \
    --stt "$STT" --stt-args "--adapter $ADAPTER --model $MODEL" \
    --speak-cmd "timeout 15 ./scripts/termux-speak.sh \"Ever tried ever failed no matter try again fail again fail better\"" \
    --speak-delay 4 --duration 22 \
    --pcm "$TMP/live_s42.raw" --report "$TMP/live_s42.json" \
    > "$TMP/live_s42.summary.json" 2>> "$LOG" || true
cat "$TMP/live_s42.summary.json" | tee -a "$LOG"
jq -e '.speech_count >= 1' "$TMP/live_s42.json" >/dev/null || fail "S4.2: no speech final captured"
LAT=$(jq -r '.speech_latency_max_s // empty' "$TMP/live_s42.json")
[ -n "$LAT" ] || fail "S4.2: no latency value"
awk -v a="$LAT" 'BEGIN{exit !(a<=3.0)}' || fail "S4.2: speech latency ${LAT}s > 3.0s"
TRANSCRIPT=$(jq -r '.transcript' "$TMP/live_s42.json")
printf '%s\n' "$TRANSCRIPT" | grep -Eqi 'ever|matter|again|better|fail' \
    || fail "S4.2/S4.3: transcript does not match the spoken phrase: $TRANSCRIPT"
say "S4.2 OK: latency ${LAT}s (TTS acoustic loopback)"
say "S4.3 evidence (synthetic TTS voice; human-voice demo still pending): $TRANSCRIPT"
printf '%s\n' "$TRANSCRIPT" > "$TMP/s43_transcript.txt"

say
say "== S4.4a: no capture server -> clear error, no hang =="
RC=0
timeout 10 sh "$CAPTURE" --no-start-server --port 4799 > "$TMP/s44_noserver.log" 2>&1 || RC=$?
[ "$RC" -ne 0 ] || fail "S4.4a: capture without server unexpectedly succeeded"
[ "$RC" -ne 124 ] || fail "S4.4a: capture without server hung"
grep -qi "no PulseAudio server" "$TMP/s44_noserver.log" || fail "S4.4a: error message not clear"
say "S4.4a OK: rc=$RC, $(grep -i 'no PulseAudio server' "$TMP/s44_noserver.log" | head -1)"

say
say "== S4.4b: microphone/OpenSL failure -> clear error =="
# Reproducible failure injection: a fake PulseAudio that reports the same
# OpenSL error as a busy/denied device.  We do NOT revoke the real
# RECORD_AUDIO permission: doing so made the Termux app crash in testing.
FAKE="$TMP/fakeprefix"
mkdir -p "$FAKE/bin" "$TMP/fakehome"
cat > "$FAKE/bin/pulseaudio" <<'EOS'
#!/bin/sh
echo "E: [pulseaudio] module-sles-source.c: Failed to initialize OpenSL ES: error 9" >&2
exit 1
EOS
cat > "$FAKE/bin/pactl" <<'EOS'
#!/bin/sh
exit 1
EOS
cat > "$FAKE/bin/parec" <<'EOS'
#!/bin/sh
exit 1
EOS
chmod 755 "$FAKE/bin/pulseaudio" "$FAKE/bin/pactl" "$FAKE/bin/parec"
RC=0
HOME="$TMP/fakehome" TERMUX_PREFIX="$FAKE" timeout 25 sh "$CAPTURE" --mode termux --check --port 4723 \
    > "$TMP/s44_opensl.log" 2>&1 || RC=$?
[ "$RC" -ne 0 ] || fail "S4.4b: capture unexpectedly succeeded with an OpenSL failure"
[ "$RC" -ne 124 ] || fail "S4.4b: capture hung with an OpenSL failure"
grep -qi "OpenSL ES" "$TMP/s44_opensl.log" || fail "S4.4b: OpenSL error not surfaced"
grep -qi "mic busy or permission denied" "$TMP/s44_opensl.log" || fail "S4.4b: operator guidance missing"
say "S4.4b OK: rc=$RC, $(grep -i 'mic busy or permission denied' "$TMP/s44_opensl.log" | head -1)"

say
say "== S4.4c: core does not hang when capture fails =="
RC=0
timeout 25 sh scripts/stt-mic.sh --no-start-server --port 4799 -- --adapter "$ECHO" \
    > "$TMP/s44_sttmic.out" 2> "$TMP/s44_sttmic.err" || RC=$?
[ "$RC" -ne 124 ] || fail "S4.4c: stt-mic.sh hung when capture failed"
grep -q '"type":"eof"' "$TMP/s44_sttmic.out" || fail "S4.4c: core did not close with eof"
grep -qi "no PulseAudio server" "$TMP/s44_sttmic.err" || fail "S4.4c: capture error not propagated"
say "S4.4c OK: rc=$RC, core emitted eof and the error was clear"

say
say "== cleanup =="
sleep 1
if pgrep -f "[s]ource_name=stt_mic_47" >/dev/null 2>&1; then
    fail "a capture PulseAudio server was left running"
fi
say "no capture servers left"

say
say "ALL STAGE 4 CHECKS OK"
