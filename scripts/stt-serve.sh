#!/bin/sh
# stt-serve — one-shot ops entrypoint for the remote server (Stage 6, S6.6).
#
#   ./scripts/stt-serve.sh                          # engine from config
#   ./scripts/stt-serve.sh --engine sherpa          # mic capture + sttd
#   ./scripts/stt-serve.sh --listen 0.0.0.0:4719    # expose on the LAN
#   ./scripts/stt-serve.sh --max-clients 16
#   ./scripts/stt-serve.sh --pipeline 'cat var/tmp/events.ndjson'
#   ./scripts/stt-serve.sh --show-token -- --partials
#
# Options before `--`: --engine NAME  --listen ADDR (default 127.0.0.1:4719,
#   contract §9.1)  --max-clients N  --pipeline CMD  --no-wakelock
#   --show-token.  --engine/--pipeline are passed through to sttd, which
#   builds the "scripts/stt-mic.sh --engine NAME" session command itself
#   (D20); anything after `--` goes verbatim to sttd (Go flags: last wins).
#
# Termux wakelock (best-effort): held while serving, released on exit —
#   without it Android suspends the capture when the screen goes off
#   (OPERACION §7.1). Never fails because of the wakelock.
#
# Single instance, newest wins: a second stt-serve.sh takes over from a
#   stale one (same pattern as scripts/stt-mic.sh). Exit code: sttd's;
#   2 = bad usage. Runtime files: var/tmp/serve/ (never outside var/).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
STTD=${STTD:-"$ROOT/var/bin/sttd"}
LISTEN=127.0.0.1:4719
ENGINE=; MAXC=; PIPELINE=
WAKELOCK=1
SHOW_TOKEN=0

usage() {
	sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
	case "$1" in
		--engine)      [ $# -ge 2 ] || { echo "error: --engine needs a value" >&2; exit 2; }
		               ENGINE=$2; shift 2 ;;
		--listen)      [ $# -ge 2 ] || { echo "error: --listen needs a value" >&2; exit 2; }
		               LISTEN=$2; shift 2 ;;
		--max-clients) [ $# -ge 2 ] || { echo "error: --max-clients needs a value" >&2; exit 2; }
		               MAXC=$2; shift 2 ;;
		--pipeline)    [ $# -ge 2 ] || { echo "error: --pipeline needs a value" >&2; exit 2; }
		               PIPELINE=$2; shift 2 ;;
		--no-wakelock) WAKELOCK=0; shift ;;
		--show-token)  SHOW_TOKEN=1; shift ;;
		--)            shift; break ;;
		-h|--help)     usage; exit 0 ;;
		*)             echo "error: unknown option: $1 (see --help)" >&2; exit 2 ;;
	esac
done

if [ -n "${MAXC:-}" ]; then
	case "$MAXC" in
		*[!0-9]*) echo "error: --max-clients wants a number, got: $MAXC" >&2; exit 2 ;;
	esac
fi

[ -x "$STTD" ] || { echo "error: $STTD not found (run: make core)" >&2; exit 1; }

# sttd loads config/stt.toml and resolves the pipeline command and model
# paths against its CWD; anchor everything to the repo root.
cd "$ROOT"
SRV="$ROOT/var/tmp/serve"
mkdir -p "$SRV"
PIDFILE="$SRV/serve.pid"
STTDPIDFILE="$SRV/sttd.pid"
STTD_LOG="$SRV/sttd.stderr.log"

# --show-token: resolve the token exactly as the server will (same config
# and post-`--` flags); at this point "$@" still holds the extras.
SHOW_TOK=
if [ "$SHOW_TOKEN" = "1" ]; then
	SHOW_TOK=$("$STTD" --print-token "$@" 2>/dev/null) || SHOW_TOK=
fi

# Termux wakelock, best-effort (never fatal, §7.1).
WAKE_HELD=0
release_wakelock() {
	if [ "$WAKE_HELD" = "1" ]; then
		command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock >/dev/null 2>&1 || true
		echo "stt-serve: wakelock released"
		WAKE_HELD=0
	fi
	return 0
}
if [ "$WAKELOCK" = "1" ]; then
	if command -v termux-wake-lock >/dev/null 2>&1; then
		if termux-wake-lock >/dev/null 2>&1; then
			WAKE_HELD=1
			echo "stt-serve: wakelock held"
		else
			echo "stt-serve: wakelock: unavailable (skipped)"
		fi
	else
		echo "stt-serve: wakelock: unavailable (skipped)"
	fi
fi

STTD_PID=
STTD_PID_WRITTEN=
STTD_RC=0

# Teardown: stop sttd (TERM, 5 s grace, KILL), release the wakelock, drop
# our pidfiles. Ignoring further signals keeps a second Ctrl-C from
# aborting the cleanup half-way (stt-mic.sh lesson).
cleanup() {
	trap '' INT TERM HUP
	if [ -n "${STTD_PID:-}" ]; then
		kill -TERM "$STTD_PID" 2>/dev/null || true
		i=0
		while kill -0 "$STTD_PID" 2>/dev/null && [ "$i" -lt 50 ]; do
			sleep 0.1
			i=$((i + 1))
		done
		kill -KILL "$STTD_PID" 2>/dev/null || true
		wait "$STTD_PID" 2>/dev/null || STTD_RC=$?
		STTD_PID=
	fi
	release_wakelock
	if [ -f "$PIDFILE" ] && [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ]; then
		rm -f "$PIDFILE"
	fi
	if [ -n "${STTD_PID_WRITTEN:-}" ] && [ -f "$STTDPIDFILE" ] \
		&& [ "$(cat "$STTDPIDFILE" 2>/dev/null)" = "$STTD_PID_WRITTEN" ]; then
		rm -f "$STTDPIDFILE"
	fi
	return 0
}
trap cleanup EXIT
trap 'cleanup; exit "$STTD_RC"' INT TERM HUP

# Single-instance takeover (stt-mic.sh pattern): an uncleanly-exited
# previous serve would keep port 4719 and its session pipeline alive.
# Newest run wins: tell the old one to die (its trap tears down its sttd),
# then sweep an orphaned sttd its trap never reached (SIGKILLed serve).
if [ -f "$PIDFILE" ]; then
	OLDPID=$(cat "$PIDFILE" 2>/dev/null || true)
	if [ -n "$OLDPID" ] && [ "$OLDPID" != "$$" ] && kill -0 "$OLDPID" 2>/dev/null; then
		echo "stt-serve: taking over from previous instance (pid $OLDPID)" >&2
		kill -TERM "$OLDPID" 2>/dev/null || true
		i=0
		while kill -0 "$OLDPID" 2>/dev/null && [ "$i" -lt 60 ]; do
			sleep 0.1
			i=$((i + 1))
		done
		kill -KILL "$OLDPID" 2>/dev/null || true
	fi
fi
if [ -f "$STTDPIDFILE" ]; then
	OLDSTTD=$(cat "$STTDPIDFILE" 2>/dev/null || true)
	if [ -n "$OLDSTTD" ] && kill -0 "$OLDSTTD" 2>/dev/null; then
		echo "stt-serve: stopping leftover sttd (pid $OLDSTTD)" >&2
		kill -TERM "$OLDSTTD" 2>/dev/null || true
		i=0
		while kill -0 "$OLDSTTD" 2>/dev/null && [ "$i" -lt 30 ]; do
			sleep 0.1
			i=$((i + 1))
		done
		kill -KILL "$OLDSTTD" 2>/dev/null || true
	fi
fi
echo $$ >"$PIDFILE"

# sttd supervises the session pipeline itself (D20): --engine becomes
# "scripts/stt-mic.sh --engine NAME" inside sttd, --pipeline is verbatim.
# "$@" holds the post-`--` extras; prepend our flags without touching them.
if [ -n "$ENGINE" ]; then set -- --engine "$ENGINE" "$@"; fi
if [ -n "$PIPELINE" ]; then set -- --pipeline "$PIPELINE" "$@"; fi
if [ -n "$MAXC" ]; then set -- --max-clients "$MAXC" "$@"; fi
set -- --listen "$LISTEN" "$@"

: >"$STTD_LOG"
"$STTD" "$@" >"$STTD_LOG" 2>&1 &
STTD_PID=$!
STTD_PID_WRITTEN=$STTD_PID
echo "$STTD_PID" >"$STTDPIDFILE"

# Bounded wait for the bind (observable log line, not a fixed sleep).
ADDR=
i=0
while :; do
	ADDR=$(sed -n 's|^sttd: listening on ws://\([^/]*\)/v1/feed.*|\1|p' "$STTD_LOG" | tail -n 1)
	[ -n "$ADDR" ] && break
	if ! kill -0 "$STTD_PID" 2>/dev/null; then
		echo "stt-serve: sttd exited during startup:" >&2
		sed 's/^/  /' "$STTD_LOG" >&2
		wait "$STTD_PID" 2>/dev/null || STTD_RC=$?
		STTD_PID=
		exit "$STTD_RC"
	fi
	if [ "$i" -ge 600 ]; then
		echo "stt-serve: sttd did not bind within 30 s (see $STTD_LOG)" >&2
		kill -TERM "$STTD_PID" 2>/dev/null || true
		sleep 1
		kill -KILL "$STTD_PID" 2>/dev/null || true
		STTD_PID=
		exit 1
	fi
	sleep 0.05
	i=$((i + 1))
done

echo "stt-serve: listening on ws://$ADDR/v1/feed (pid $STTD_PID)"
echo "stt-serve: token: var/etc/stt-token (use sttd --print-token to show)"
if [ "$SHOW_TOKEN" = "1" ] && [ -n "$SHOW_TOK" ]; then
	echo "stt-serve: token: $SHOW_TOK"
fi
echo "stt-serve: sttd log: $STTD_LOG"

RC=0
wait "$STTD_PID" || RC=$?
STTD_PID=
exit "$RC"
