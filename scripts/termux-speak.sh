#!/bin/sh
# termux-speak — speak text with Android TTS (Stage 4 demo/test helper).
#
#   ./scripts/termux-speak.sh "Ever tried ever failed"
#
# Uses the Termux:API TTS command.  In android mode (inside the chroot) it
# runs through the same uid/SELinux helper as the microphone capture, so the
# audio comes out of the phone speaker while termux-capture.sh records it.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ANDROID_ROOT=/proc/1/root
PREFIX=${TERMUX_PREFIX:-${PREFIX:-/data/data/com.termux/files/usr}}
HOME_TERMUX=${TERMUX_HOME:-/data/data/com.termux/files/home}
ENVFILE="$ROOT/var/bin/termux-mic.env"
MODE=auto
TEXT=

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --mode) MODE=$2; shift 2 ;;
        --mode=*) MODE=${1#*=}; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "error: unknown option $1" >&2; exit 2 ;;
        *) break ;;
    esac
done
[ $# -ge 1 ] || { usage; exit 2; }
TEXT=$1
shift

if [ "$MODE" = auto ]; then
    if [ "$(id -u)" != 0 ] && command -v termux-tts-speak >/dev/null 2>&1; then
        MODE=termux
    elif [ "$(id -u)" = 0 ] && [ -x "$ANDROID_ROOT$PREFIX/bin/termux-tts-speak" ]; then
        MODE=android
    else
        echo "error: cannot detect mode; use --mode termux|android" >&2
        exit 2
    fi
fi

if [ "$MODE" = termux ]; then
    exec "$PREFIX/bin/termux-tts-speak" "$TEXT" "$@"
fi

[ "$(id -u)" = 0 ] || { echo "error: android mode requires root" >&2; exit 1; }
[ -f "$ENVFILE" ] || { echo "error: run scripts/termux-mic-setup.sh first" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENVFILE"

# single-quote the text for the generated shell script
ESCAPED=$(printf '%s' "$TEXT" | sed "s/'/'\\\\''/g")
START="/data/local/tmp/stt-tts.$$.sh"
cat > "$ANDROID_ROOT$START" <<EOF
#!/system/bin/sh
export PREFIX=$PREFIX
export HOME=$HOME_TERMUX
export PATH=\$PREFIX/bin:/system/bin
export TMPDIR=\$PREFIX/tmp
export LD_LIBRARY_PATH=\$PREFIX/lib
exec \$PREFIX/bin/runas-ctx $TERMUX_UID '$TERMUX_CTX' \$PREFIX/bin/termux-tts-speak '$ESCAPED'
EOF
chmod 755 "$ANDROID_ROOT$START"
nsenter -t 1 -m -p -- /system/bin/sh "$START"
rc=$?
rm -f "$ANDROID_ROOT$START"
exit "$rc"
