#!/bin/sh
# stt-mic — microphone -> `stt stream` (Stage 4 convenience wrapper).
#
#   ./scripts/stt-mic.sh
#   ./scripts/stt-mic.sh --engine sherpa      # sherpa zipformer + partials
#   ./scripts/stt-mic.sh --engine moonshine   # explicit default engine
#   ./scripts/stt-mic.sh --port 4713 -- --adapter adapters/echo/stt-adapter-echo
#
# Capture options (before `--`) are passed to scripts/termux-capture.sh:
#   --engine NAME  --mode auto|termux|android  --port N  --rate N  --channels N
#   --device NAME  --latency-ms N  --no-start-server  --check
#
# --engine NAME expands to the adapter/model pair of a known engine
# (moonshine = config default; sherpa = kroko EN 2025 zipformer, --partials on;
# sherpa-es = kroko es; sherpa-en-2023 = legacy int8 zipformer; whisper =
# whisper-small offline, accuracy eval only — finals only, RTF > 1). Anything after
# `--` goes verbatim to `stt stream` and wins over the preset (Go flags: last
# one wins), e.g. `--engine sherpa -- --partials=false`. With no --engine and
# no explicit --adapter, config/stt.toml decides.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
STT=${STT:-"$ROOT/var/bin/stt"}
CAP_ARGS=

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --engine)   [ $# -ge 2 ] || { echo "error: --engine needs a value" >&2; exit 2; }
                    ENGINE=$2; shift 2 ;;
        --mode|--port|--rate|--channels|--device|--latency-ms)
            [ $# -ge 2 ] || { echo "error: $1 needs a value" >&2; exit 2; }
            CAP_ARGS="$CAP_ARGS $1 $2"
            shift 2
            ;;
        --no-start-server|--start-server|--check|--list)
            CAP_ARGS="$CAP_ARGS $1"
            shift
            ;;
        --) shift; break ;;
        -h|--help) usage; exit 0 ;;
        *) break ;;
    esac
done

[ -x "$STT" ] || { echo "error: $STT not found (run: make core)" >&2; exit 1; }

# `stt` loads config/stt.toml and resolves the adapter command and relative
# model paths against its CWD.  Running from another directory (e.g.
# scripts/) would silently fall back to built-in defaults (echo adapter), so
# anchor the whole pipeline to the repo root.
cd "$ROOT"

# Single-instance takeover: an uncleanly-exited previous pipeline (lost
# terminal, phone UI kill, timeout...) keeps capturing AND inferring in the
# background — several stacked instances made the phone hot and starved the
# CPU (Sesión 007).  Newest run wins: tell the old one to die (its own trap
# cleans up its capture children) and wait briefly for it.
PIDFILE="$ROOT/var/tmp/stage4/mic-session.pid"
if [ -f "$PIDFILE" ]; then
    OLDPID=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$OLDPID" ] && [ "$OLDPID" != "$$" ] && kill -0 "$OLDPID" 2>/dev/null; then
        echo "stt-mic: taking over from stale session (pid $OLDPID)" >&2
        kill -TERM "$OLDPID" 2>/dev/null || true
        i=0
        while kill -0 "$OLDPID" 2>/dev/null && [ "$i" -lt 30 ]; do
            sleep 0.1; i=$((i + 1))
        done
        kill -KILL "$OLDPID" 2>/dev/null || true
    fi
fi
echo $$ > "$PIDFILE"

# --engine: shorthand for the adapter/model pair (explicit flags after `--`
# win over these: Go flag parsing keeps the last occurrence).
ENGINE_ARGS=""
case "${ENGINE:-}" in
    "")        ;;
    moonshine) ENGINE_ARGS="--adapter adapters/moonshine/stt-adapter-moonshine --model var/models/moonshine-tiny" ;;
    sherpa)    ENGINE_ARGS="--adapter adapters/sherpa/stt-adapter-sherpa --model var/models/sherpa-zipformer-en-kroko"
               # partials on by default unless the caller brings their own
               # (--partials or --partials=false after `--`).
               case " $* " in *" --partials"*) ;; *) ENGINE_ARGS="$ENGINE_ARGS --partials" ;; esac ;;
    sherpa-es) ENGINE_ARGS="--adapter adapters/sherpa/stt-adapter-sherpa --model var/models/sherpa-zipformer-es"
               case " $* " in *" --partials"*) ;; *) ENGINE_ARGS="$ENGINE_ARGS --partials" ;; esac ;;
    sherpa-en-2023)
               ENGINE_ARGS="--adapter adapters/sherpa/stt-adapter-sherpa --model var/models/sherpa-zipformer-en"
               case " $* " in *" --partials"*) ;; *) ENGINE_ARGS="$ENGINE_ARGS --partials" ;; esac ;;
    whisper)   ENGINE_ARGS="--adapter adapters/whisper/stt-adapter-whisper --model var/models/whisper-small" ;;
    echo)      ENGINE_ARGS="--adapter adapters/echo/stt-adapter-echo" ;;
    *)         echo "stt-mic: unknown engine: $ENGINE (moonshine|sherpa|sherpa-es|sherpa-en-2023|whisper|echo)" >&2; exit 2 ;;
esac

# --check/--list are capture-only shortcuts.
case " $CAP_ARGS " in
    *" --check "*|*" --list "*)
        exec "$ROOT/scripts/termux-capture.sh" $CAP_ARGS
        ;;
esac

FIFO="$ROOT/var/tmp/stage4/mic.$$.fifo"
mkdir -p "$ROOT/var/tmp/stage4"
rm -f "$FIFO"
mkfifo "$FIFO"

CAP_PID=
STT_PID=
cleanup() {
    # Ignore further signals while tearing down: a second Ctrl-C used to
    # abort the cleanup half-way and leave capture/server children behind.
    trap '' INT TERM
    [ -n "${STT_PID:-}" ] && kill "$STT_PID" 2>/dev/null || true
    [ -n "${CAP_PID:-}" ] && kill "$CAP_PID" 2>/dev/null || true
    STT_PID=
    CAP_PID=
    rm -f "$FIFO"
    if [ -f "$PIDFILE" ] && [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ]; then
        rm -f "$PIDFILE"
    fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

# shellcheck disable=SC2086
"$ROOT/scripts/termux-capture.sh" $CAP_ARGS > "$FIFO" &
CAP_PID=$!

# shellcheck disable=SC2086
"$STT" stream $ENGINE_ARGS "$@" < "$FIFO" &
STT_PID=$!
RC=0
wait "$STT_PID" || RC=$?
STT_PID=

# The reader is gone.  If the capture side is still alive, stopping it is
# expected (Ctrl-C / normal end); only a capture process that already exited
# with an error is a capture failure.
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
    echo "error: microphone capture failed (status $CAP_RC)" >&2
    exit 1
fi
exit "$RC"
