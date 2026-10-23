#!/bin/sh
# stt-captions — terminal live captions: microphone -> `stt stream` -> text.
#
#   ./scripts/stt-captions.sh
#   ./scripts/stt-captions.sh --engine sherpa    # sherpa zipformer, partials on
#   ./scripts/stt-captions.sh --port 4717        # capture opts (see stt-mic.sh)
#   ./scripts/stt-captions.sh -- --partials      # opts after -- go to `stt stream`
#   ./scripts/stt-captions.sh --raw              # raw NDJSON instead of captions
#   ./scripts/stt-captions.sh --no-log           # do not save the session NDJSON
#   ./scripts/stt-captions.sh --log FILE         # custom session log path
#   ./scripts/stt-captions.sh --render-only < session.ndjson   # replay as captions
#
# Captions are one line per speech segment: Moonshine emits only `final`
# events, so text appears at natural pauses (~0.5-1.3 s after the segment
# ends; S4.2 measured 1.3 s end-to-end). The session is saved to
# var/tmp/demo/ by default (replayable with --render-only).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MIC="$ROOT/scripts/stt-mic.sh"
usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

RAW=0; RENDER_ONLY=0; LOG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --raw) RAW=1; shift ;;
        --render-only) RENDER_ONLY=1; shift ;;
        --no-log) LOG="none"; shift ;;
        --log) [ $# -ge 2 ] || { echo "error: --log needs a value" >&2; exit 2; }
               LOG="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        *) break ;;
    esac
done

# ---- passthrough modes ------------------------------------------------------
if [ "$RENDER_ONLY" -eq 0 ] && [ "$RAW" -eq 1 ]; then
    exec sh "$MIC" "$@"          # raw stt-events/1 NDJSON, nothing else
fi

if [ "$RENDER_ONLY" -eq 0 ]; then
    if [ -z "$LOG" ]; then
        mkdir -p "$ROOT/var/tmp/demo"
        LOG="$ROOT/var/tmp/demo/captions-$(date +%Y%m%d-%H%M%S).ndjson"
    elif [ "$LOG" = "none" ]; then
        LOG=""
    fi
    # Keep the advertised promise: raw stt-events/1 lines land in the session
    # log as they arrive (replayable with --render-only). Empty LOG = --no-log.
    [ -n "$LOG" ] && exec 3>>"$LOG"
fi

# ---- rendering --------------------------------------------------------------
if [ -t 1 ]; then
    ESC=$(printf '\033'); B="${ESC}[1m"; D="${ESC}[2m"; C="${ESC}[36m"
    RED="${ESC}[31m"; R="${ESC}[0m"
else
    B=""; D=""; C=""; RED=""; R=""
fi

fmt_t() {
    s=$(printf '%.0f' "$1" 2>/dev/null || echo 0)
    [ -n "$s" ] || s=0
    printf '%02d:%02d' $((s / 60)) $((s % 60))
}

IND=0   # is the "listening" indicator currently on screen?
show_ind() {
    [ "$IND" -eq 1 ] && return 0
    if [ -t 1 ]; then printf '%s● listening…%s' "$D" "$R"; IND=1; fi
}
hide_ind() {
    [ "$IND" -eq 0 ] && return 0
    if [ -t 1 ]; then printf '\033[2K\r'; fi
    IND=0
}
end_line() { hide_ind; printf '%s\n' "— captions ended —"; }
trap end_line EXIT
render_stream() {
    while IFS= read -r ev; do
        [ -n "$ev" ] || continue
        [ -n "$LOG" ] && printf '%s\n' "$ev" >&3
        row=$(printf '%s' "$ev" | jq -r '
            select(.type != "final" or ((.text // "") != ""))
            | [(.type // ""), (.text // ""), (.t0 // 0), (.message // ""),
               ((.audio_s // 0) * 100 | round / 100),
               ((.skipped_s // 0) * 100 | round / 100)]
            | map(tostring) | join("\u001f")' 2>/dev/null) || continue
        OIFS=$IFS
        IFS=$(printf '\037')   # unit separator: non-whitespace, keeps empty fields
        # shellcheck disable=SC2046  # deliberate split on US
        read -r type text t0 message audio_s skipped_s <<EOF
$row
EOF
        IFS=$OIFS
        case "$type" in
            final)
                hide_ind
                printf '%s[%s]%s %s%s%s\n' "$C" "$(fmt_t "$t0")" "$R" "$B" "$text" "$R"
                show_ind
                ;;
            partial)
                hide_ind
                printf '%s… %s%s' "$D" "$text" "$R"
                IND=1   # interim text occupies the line; next event clears it
                ;;
            error)
                hide_ind
                printf '%s! error: %s%s\n' "$RED" "$message" "$R"
                show_ind
                ;;
            eof)
                hide_ind
                printf '%s— stream end: %ss audio, %ss silence skipped —%s\n' \
                    "$D" "$audio_s" "$skipped_s" "$R"
                ;;
            *) : ;;   # start/unknown types: ignored (CONTRATOS §3)
        esac
    done
}

if [ "$RENDER_ONLY" -eq 1 ]; then
    render_stream
    exit 0
fi

printf '%sstt-captions%s — speak; captions appear at pauses (Ctrl-C to stop)\n' "$B" "$R"
[ -n "$LOG" ] && printf '%ssession log: %s%s\n' "$D" "$LOG" "$R"

# The mic pipeline runs detached from this shell's stdout so that a TERM to
# us (timeout, `q` wrappers...) can be forwarded: stt-mic.sh cleans up its
# own capture children when it dies, so killing it is enough.
mkdir -p "$ROOT/var/tmp/demo"
FIFO_EV="$ROOT/var/tmp/demo/events.$$.fifo"
mkfifo "$FIFO_EV"
MIC_PID=
cleanup_mic() {
    if [ -n "${MIC_PID:-}" ]; then
        kill "$MIC_PID" 2>/dev/null || true
        wait "$MIC_PID" 2>/dev/null || true
    fi
    rm -f "$FIFO_EV"
}
trap 'cleanup_mic; exit 130' INT TERM

RC=0
sh "$MIC" "$@" > "$FIFO_EV" &
MIC_PID=$!
render_stream < "$FIFO_EV" || RC=$?
cleanup_mic
exit "$RC"
