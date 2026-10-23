#!/bin/sh
# termux-capture — real microphone -> raw PCM on stdout (Stage 4).
#
# Two modes, auto-detected:
#
#   termux   run in the Termux app (normal user).  Starts a private
#            PulseAudio daemon with module-sles-source (Android OpenSL ES)
#            and streams with parec.
#
#   android  run inside this Alpine chroot as root.  Does the same, but
#            starts PulseAudio through the Termux app uid/SELinux context
#            (scripts/termux-mic-setup.sh installs the helper) and runs
#            parec through /proc/1/root.
#
# Output is raw PCM s16le, 16 kHz, mono by default, ready for:
#
#   ./scripts/termux-capture.sh | ./var/bin/stt stream
#
# or simply:
#
#   ./scripts/stt-mic.sh
#
# The script owns the PulseAudio server it starts and stops it on exit.  If a
# compatible server is already running it reuses it and leaves it alone.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ANDROID_ROOT=/proc/1/root
PREFIX=${TERMUX_PREFIX:-${PREFIX:-/data/data/com.termux/files/usr}}
HOME_TERMUX=${TERMUX_HOME:-/data/data/com.termux/files/home}
ENVFILE="$ROOT/var/bin/termux-mic.env"
PORT=4713
PORT_FIXED=0
RATE=16000
CHANNELS=1
LATENCY_MS=100
SOURCE=
MODE=auto
START_SERVER=auto
CHECK=0
LIST=0
LOGDIR="$ROOT/var/tmp/stage4"

say() { printf '%s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

usage() {
    cat <<'EOF'
usage: termux-capture.sh [options]

  --mode auto|termux|android  where the script is running (default: auto)
  --port N                    PulseAudio TCP port (default 4713; tries 4713-4723)
  --rate N                    sample rate (default 16000)
  --channels N                channels (default 1)
  --device NAME               source name (default stt_mic_<port>)
  --latency-ms N              parec latency (default 100)
  --start-server              start PulseAudio if needed (default: auto)
  --no-start-server           never start PulseAudio
  --check                     verify the microphone path, print info, exit
  --list                      list sources and sinks, exit
  -h, --help                  this help

Environment: TERMUX_PREFIX, TERMUX_HOME.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --mode) MODE=$2; shift 2 ;;
        --mode=*) MODE=${1#*=}; shift ;;
        --port) PORT=$2; PORT_FIXED=1; shift 2 ;;
        --port=*) PORT=${1#*=}; PORT_FIXED=1; shift ;;
        --rate) RATE=$2; shift 2 ;;
        --rate=*) RATE=${1#*=}; shift ;;
        --channels) CHANNELS=$2; shift 2 ;;
        --channels=*) CHANNELS=${1#*=}; shift ;;
        --device) SOURCE=$2; shift 2 ;;
        --device=*) SOURCE=${1#*=}; shift ;;
        --latency-ms) LATENCY_MS=$2; shift 2 ;;
        --latency-ms=*) LATENCY_MS=${1#*=}; shift ;;
        --start-server) START_SERVER=1; shift ;;
        --no-start-server) START_SERVER=0; shift ;;
        --check) CHECK=1; shift ;;
        --list) LIST=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

# ---- mode selection --------------------------------------------------------
if [ "$MODE" = auto ]; then
    if [ "$(id -u)" != 0 ] && command -v parec >/dev/null 2>&1; then
        MODE=termux
    elif [ "$(id -u)" = 0 ] && [ -x "$ANDROID_ROOT$PREFIX/bin/parec" ]; then
        MODE=android
    else
        die "cannot detect capture mode; use --mode termux|android"
    fi
fi

case "$MODE" in
    termux)
        [ -x "$PREFIX/bin/parec" ] || die "parec not found at $PREFIX/bin/parec"
        [ -x "$PREFIX/bin/pactl" ] || die "pactl not found at $PREFIX/bin/pactl"
        [ -x "$PREFIX/bin/pulseaudio" ] || die "pulseaudio not found at $PREFIX/bin/pulseaudio"
        HOME_TERMUX=${HOME:-$HOME_TERMUX}
        ;;
    android)
        [ "$(id -u)" = 0 ] || die "mode android requires root inside the chroot"
        [ -d "$ANDROID_ROOT$PREFIX/bin" ] || die "Termux prefix not found at $ANDROID_ROOT$PREFIX"
        [ -x "$ANDROID_ROOT$PREFIX/bin/parec" ] || die "parec not found in Termux prefix"
        if [ -f "$ENVFILE" ]; then
            # shellcheck disable=SC1090
            . "$ENVFILE"
        fi
        [ -n "${TERMUX_UID:-}" ] || TERMUX_UID=$(stat -c %u "$ANDROID_ROOT/data/data/com.termux" 2>/dev/null || true)
        [ -n "${TERMUX_UID:-}" ] || die "cannot determine Termux uid; run scripts/termux-mic-setup.sh"
        if [ -z "${TERMUX_CTX:-}" ]; then
            FILE_CTX=$(nsenter -t 1 -m -p -- /system/bin/sh -c "ls -Z $PREFIX/bin/bash" 2>/dev/null | awk '{print $1}')
            [ -n "$FILE_CTX" ] || die "cannot determine Termux SELinux context; run scripts/termux-mic-setup.sh"
            TERMUX_CTX=$(printf '%s' "$FILE_CTX" | sed 's/^u:object_r:/u:r:/')
        fi
        PREFIX=${TERMUX_PREFIX:-$PREFIX}
        HOME_TERMUX=${TERMUX_HOME:-$HOME_TERMUX}
        ;;
    *) die "invalid --mode: $MODE (use termux or android)" ;;
esac

[ -n "$SOURCE" ] || SOURCE="stt_mic_$PORT"
RUNTIME="$HOME_TERMUX/.stt/pulse"
LOG="$LOGDIR/pulseaudio.log"
mkdir -p "$LOGDIR"

SERVER_STARTED=0
SERVER_PID=
PAREC_PID=
START_SCRIPT=

# ---- helpers ---------------------------------------------------------------
if [ "$MODE" = android ]; then
    mkdir -p "$ANDROID_ROOT$RUNTIME"
    chown -R "$TERMUX_UID:$TERMUX_UID" "$ANDROID_ROOT$HOME_TERMUX/.stt" 2>/dev/null || true

    pactl_run() {
        PULSE_SERVER="127.0.0.1:$PORT" HOME="$HOME_TERMUX" TMPDIR="$PREFIX/tmp" \
        LD_LIBRARY_PATH="$PREFIX/lib" \
            chroot "$ANDROID_ROOT" "$PREFIX/bin/pactl" "$@"
    }
    parec_run() {
        PULSE_SERVER="127.0.0.1:$PORT" HOME="$HOME_TERMUX" TMPDIR="$PREFIX/tmp" \
        LD_LIBRARY_PATH="$PREFIX/lib" \
            chroot "$ANDROID_ROOT" "$PREFIX/bin/parec" "$@"
    }
else
    mkdir -p "$RUNTIME"
    pactl_run() {
        PULSE_SERVER="127.0.0.1:$PORT" "$PREFIX/bin/pactl" "$@"
    }
    parec_run() {
        PULSE_SERVER="127.0.0.1:$PORT" "$PREFIX/bin/parec" "$@"
    }
fi

server_up() { pactl_run info >/dev/null 2>&1; }

source_up() {
    pactl_run list short sources 2>/dev/null | awk '{print $2}' | grep -qx "$SOURCE"
}

choose_port() {
    [ "$PORT_FIXED" = 1 ] && return 0
    p=4713
    while [ "$p" -le 4723 ]; do
        PORT=$p
        if ! server_up; then return 0; fi
        if source_up; then return 0; fi
        p=$((p + 1))
    done
    die "ports 4713-4723 are busy with incompatible PulseAudio servers"
}

start_server() {
    if server_up && source_up; then
        return 0
    fi
    if server_up && ! source_up; then
        die "PulseAudio is running on port $PORT but source $SOURCE is missing"
    fi
    if [ "$MODE" = android ] && [ ! -x "$ANDROID_ROOT$PREFIX/bin/runas-ctx" ]; then
        die "missing $PREFIX/bin/runas-ctx; run scripts/termux-mic-setup.sh"
    fi

    say "starting PulseAudio (mode $MODE, port $PORT, source $SOURCE)" >&2
    : > "$LOG"

    if [ "$MODE" = android ]; then
        START_SCRIPT="/data/local/tmp/stt-pa-start.$$.sh"
        cat > "$ANDROID_ROOT$START_SCRIPT" <<EOF
#!/system/bin/sh
export PREFIX=$PREFIX
export HOME=$HOME_TERMUX
export PATH=\$PREFIX/bin:/system/bin
export TMPDIR=\$PREFIX/tmp
export LD_LIBRARY_PATH=\$PREFIX/lib
export PULSE_RUNTIME_PATH=$HOME_TERMUX/.stt/pulse
exec \$PREFIX/bin/runas-ctx $TERMUX_UID '$TERMUX_CTX' \$PREFIX/bin/pulseaudio \\
    -n --exit-idle-time=30 --daemonize=no --log-target=stderr \\
    --load="module-sles-source source_name=$SOURCE rate=$RATE channels=$CHANNELS" \\
    --load="module-native-protocol-tcp auth-anonymous=1 listen=127.0.0.1 port=$PORT"
EOF
        chmod 755 "$ANDROID_ROOT$START_SCRIPT"
        nsenter -t 1 -m -p -- /system/bin/sh "$START_SCRIPT" > "$LOG" 2>&1 &
        SERVER_PID=$!
    else
        PULSE_RUNTIME_PATH="$RUNTIME" "$PREFIX/bin/pulseaudio" \
            -n --exit-idle-time=30 --daemonize=no --log-target=stderr \
            --load="module-sles-source source_name=$SOURCE rate=$RATE channels=$CHANNELS" \
            --load="module-native-protocol-tcp auth-anonymous=1 listen=127.0.0.1 port=$PORT" \
            > "$LOG" 2>&1 &
        SERVER_PID=$!
    fi
    SERVER_STARTED=1

    i=0
    while [ "$i" -lt 30 ]; do
        if server_up && source_up; then
            say "PulseAudio ready (pid $SERVER_PID)" >&2
            return 0
        fi
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            break
        fi
        sleep 0.2
        i=$((i + 1))
    done

    err "microphone capture could not start"
    if grep -qi "OpenSL ES" "$LOG" 2>/dev/null; then
        err "the Android audio stack rejected the capture client (mic busy or permission denied)."
        err "  - grant Microphone permission to Termux and Termux:API"
        err "  - close other apps using the microphone (calls, recorders)"
        err "  - run scripts/termux-mic-setup.sh inside the chroot (root)"
    fi
    err "PulseAudio log ($LOG):"
    tail -20 "$LOG" >&2 || true
    stop_server
    exit 1
}

stop_server() {
    [ "$SERVER_STARTED" = 1 ] || return 0
    # Kill the PulseAudio child by its unique source name first: the wrapper
    # (nsenter -> sh -> runas-ctx -> pulseaudio) does not forward signals, so
    # killing only $SERVER_PID leaves an orphan server behind (observed as a
    # stale stt_mic_* daemon after an interrupted session). Escalate to KILL
    # and verify; the wrapper is then matched through its start-script path.
    pkill -TERM -f "[s]ource_name=$SOURCE" 2>/dev/null || true
    [ -n "${SERVER_PID:-}" ] && kill -TERM "$SERVER_PID" 2>/dev/null || true
    [ -n "${START_SCRIPT:-}" ] && pkill -TERM -f "$START_SCRIPT" 2>/dev/null || true
    i=0
    while pgrep -f "[s]ource_name=$SOURCE" >/dev/null 2>&1 && [ "$i" -lt 20 ]; do
        sleep 0.05
        i=$((i + 1))
    done
    pkill -KILL -f "[s]ource_name=$SOURCE" 2>/dev/null || true
    [ -n "${SERVER_PID:-}" ] && kill -KILL "$SERVER_PID" 2>/dev/null || true
    [ -n "${START_SCRIPT:-}" ] && pkill -KILL -f "$START_SCRIPT" 2>/dev/null || true
    if [ "$MODE" = android ]; then
        [ -n "${START_SCRIPT:-}" ] && rm -f "$ANDROID_ROOT$START_SCRIPT"
        rm -rf "$ANDROID_ROOT$RUNTIME"
    else
        rm -rf "$RUNTIME"
    fi
    SERVER_STARTED=0
    SERVER_PID=
    START_SCRIPT=
}

cleanup() {
    # A second Ctrl-C/TERM while cleanup runs must not abort the cleanup
    # half-way (that is how the orphan server + start script survived).
    trap '' INT TERM
    if [ -n "${PAREC_PID:-}" ]; then
        kill "$PAREC_PID" 2>/dev/null || true
        PAREC_PID=
    fi
    stop_server
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

list_info() {
    say "mode:     $MODE"
    say "prefix:   $PREFIX"
    say "server:   $([ server_up ] && echo up || echo down) (port $PORT)"
    if server_up; then
        say "sources:"
        pactl_run list short sources || true
        say "sinks:"
        pactl_run list short sinks || true
    fi
}

# ---- main ------------------------------------------------------------------
if [ "$LIST" = 1 ]; then
    choose_port
    if ! server_up && [ "$START_SERVER" != 0 ]; then start_server; fi
    list_info
    exit 0
fi

choose_port

if [ "$CHECK" = 1 ]; then
    if ! server_up && [ "$START_SERVER" != 0 ]; then
        start_server
    elif server_up && ! source_up && [ "$START_SERVER" != 0 ]; then
        start_server
    fi
    list_info
    if server_up && source_up; then
        say "OK: source $SOURCE is available"
        exit 0
    fi
    die "source $SOURCE is not available"
fi

if [ "$START_SERVER" = auto ]; then
    START_SERVER=1
fi
if [ "$START_SERVER" = 1 ]; then
    start_server
else
    server_up || die "no PulseAudio server on port $PORT (and --no-start-server was given)"
    source_up || die "source $SOURCE not found on the running server"
fi

say "capturing from $SOURCE (${RATE} Hz, ${CHANNELS} ch, s16le)" >&2
parec_run --format=s16le --rate="$RATE" --channels="$CHANNELS" \
    --device="$SOURCE" --latency-msec="$LATENCY_MS" &
PAREC_PID=$!
wait "$PAREC_PID"
rc=$?
PAREC_PID=
if [ "$rc" -ne 0 ]; then
    err "parec exited with status $rc"
    [ -f "$LOG" ] && tail -10 "$LOG" >&2 || true
fi
exit "$rc"
