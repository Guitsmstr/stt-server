#!/bin/sh
# stt-mic — microphone -> `stt stream` (Stage 4 convenience wrapper).
#
#   ./scripts/stt-mic.sh
#   ./scripts/stt-mic.sh --port 4713 -- --adapter adapters/echo/stt-adapter-echo
#
# Capture options (before `--`) are passed to scripts/termux-capture.sh:
#   --mode auto|termux|android  --port N  --rate N  --channels N
#   --device NAME  --latency-ms N  --no-start-server  --check
#
# Everything after `--` (or after the first unknown option) goes to
# `stt stream`; with no arguments the adapter/model from config/stt.toml are
# used.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
STT=${STT:-"$ROOT/var/bin/stt"}
CAP_ARGS=

usage() {
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
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
    [ -n "${STT_PID:-}" ] && kill "$STT_PID" 2>/dev/null || true
    [ -n "${CAP_PID:-}" ] && kill "$CAP_PID" 2>/dev/null || true
    rm -f "$FIFO"
    if [ -f "$PIDFILE" ] && [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ]; then
        rm -f "$PIDFILE"
    fi
}
trap cleanup EXIT INT TERM HUP

# shellcheck disable=SC2086
"$ROOT/scripts/termux-capture.sh" $CAP_ARGS > "$FIFO" &
CAP_PID=$!

"$STT" stream "$@" < "$FIFO" &
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
