#!/bin/sh
# stt-mic-local — desktop microphone (or WAV replay) -> `stt stream`.
#
# Local counterpart of scripts/stt-mic.sh (Termux/Android-only): same engine
# presets and `stt stream` wiring, but the capture side is the host
# (macOS/Linux) instead of termux-capture.sh. A local sttd session runs this
# via --pipeline (docs/OPERACION.md §7):
#
#   ./scripts/stt-serve.sh --pipeline 'scripts/stt-mic-local.sh --engine whisper'
#
#   ./scripts/stt-mic-local.sh --engine whisper
#   ./scripts/stt-mic-local.sh --engine whisper --wav tests/assets/beckett.wav
#   ./scripts/stt-mic-local.sh --engine echo -- --partials
#
# Options (before `--`):
#   --engine NAME    moonshine|sherpa|sherpa-es|sherpa-en-2023|whisper|echo
#                    (same presets as scripts/stt-mic.sh; whisper =
#                    whisper-small, finals only — offline accuracy engine)
#   --wav FILE       replay FILE at real-time pace instead of the microphone
#   --device NAME    ffmpeg capture device (macOS: avfoundation audio index,
#                    default "default"; Linux: ALSA device, default "default")
#
# Anything after `--` goes verbatim to `stt stream` and wins over the preset.
#
# Requires: ffmpeg (capture + WAV -> s16le 16 kHz mono); var/bin/stt (make core).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
STT=${STT:-"$ROOT/var/bin/stt"}
ENGINE=
WAV=
DEVICE=default

usage() {
    sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --engine) [ $# -ge 2 ] || { echo "error: --engine needs a value" >&2; exit 2; }
                  ENGINE=$2; shift 2 ;;
        --wav)    [ $# -ge 2 ] || { echo "error: --wav needs a value" >&2; exit 2; }
                  WAV=$2; shift 2 ;;
        --device) [ $# -ge 2 ] || { echo "error: --device needs a value" >&2; exit 2; }
                  DEVICE=$2; shift 2 ;;
        --) shift; break ;;
        -h|--help) usage; exit 0 ;;
        *) echo "stt-mic-local: unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done

[ -x "$STT" ] || { echo "error: $STT not found (run: make core)" >&2; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || { echo "error: ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }

# `stt` loads config/stt.toml and resolves adapter commands and relative
# model paths against its CWD — anchor the pipeline to the repo root
# (same reason as scripts/stt-mic.sh).
cd "$ROOT"

# --engine: shorthand for the adapter/model pair (explicit flags after `--`
# win over these: Go flag parsing keeps the last occurrence).
ENGINE_ARGS=""
case "${ENGINE:-}" in
    "")        ;;
    moonshine) ENGINE_ARGS="--adapter adapters/moonshine/stt-adapter-moonshine --model var/models/moonshine-tiny" ;;
    sherpa)    ENGINE_ARGS="--adapter adapters/sherpa/stt-adapter-sherpa --model var/models/sherpa-zipformer-en-kroko" ;;
    sherpa-es) ENGINE_ARGS="--adapter adapters/sherpa/stt-adapter-sherpa --model var/models/sherpa-zipformer-es" ;;
    sherpa-en-2023) ENGINE_ARGS="--adapter adapters/sherpa/stt-adapter-sherpa --model var/models/sherpa-zipformer-en" ;;
    whisper)   ENGINE_ARGS="--adapter adapters/whisper/stt-adapter-whisper --model var/models/whisper-small" ;;
    echo)      ENGINE_ARGS="--adapter adapters/echo/stt-adapter-echo" ;;
    *) echo "stt-mic-local: unknown engine: $ENGINE (moonshine|sherpa|sherpa-es|sherpa-en-2023|whisper|echo)" >&2; exit 2 ;;
esac

# sherpa engines stream partials by default unless the caller decides.
case "${ENGINE:-}" in
    sherpa|sherpa-es|sherpa-en-2023)
        case " $* " in *" --partials"*) ;; *) ENGINE_ARGS="$ENGINE_ARGS --partials" ;; esac ;;
esac

FIFO="$ROOT/var/tmp/stage4/mic-local.$$.fifo"
mkdir -p "$ROOT/var/tmp/stage4"
rm -f "$FIFO"
mkfifo "$FIFO"

CAP_PID=
STT_PID=
cleanup() {
    trap '' INT TERM
    [ -n "${STT_PID:-}" ] && kill "$STT_PID" 2>/dev/null || true
    [ -n "${CAP_PID:-}" ] && kill "$CAP_PID" 2>/dev/null || true
    STT_PID=
    CAP_PID=
    rm -f "$FIFO"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

if [ -n "$WAV" ]; then
    # -re paces the replay like a live microphone; the adapter contract is
    # raw s16le 16 kHz mono PCM on stdout.
    ffmpeg -nostdin -v error -re -i "$WAV" -f s16le -ar 16000 -ac 1 - > "$FIFO" &
else
    case "$(uname -s)" in
        Darwin) ffmpeg -nostdin -v error -f avfoundation -i ":$DEVICE" -f s16le -ar 16000 -ac 1 - > "$FIFO" & ;;
        *)      ffmpeg -nostdin -v error -f alsa -i "$DEVICE" -f s16le -ar 16000 -ac 1 - > "$FIFO" & ;;
    esac
fi
CAP_PID=$!

# shellcheck disable=SC2086
"$STT" stream $ENGINE_ARGS "$@" < "$FIFO" &
STT_PID=$!
RC=0
wait "$STT_PID" || RC=$?
STT_PID=

# The reader is gone: a capture side still alive is the normal end (Ctrl-C /
# replay finished); one that already failed is a capture failure.
CAP_RC=0
if kill -0 "$CAP_PID" 2>/dev/null; then
    kill "$CAP_PID" 2>/dev/null || true
    wait "$CAP_PID" 2>/dev/null || true
else
    wait "$CAP_PID" 2>/dev/null || CAP_RC=$?
fi
CAP_PID=
rm -f "$FIFO"

if [ "$CAP_RC" -ne 0 ]; then
    echo "error: capture failed (status $CAP_RC)" >&2
    exit 1
fi
exit "$RC"
