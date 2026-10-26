#!/bin/sh
# stt-serve-laya — kroko-es + Laya corrector as a server (OPERACION §7.6).
#
# One command: starts the Laya judge (if it is not already answering) and the
# sttd server with the keyboard-style corrector inside the session pipeline.
# Speak to the phone mic; clients connect to ws://<phone-ip>:4719/v1/feed with
# the printed token and receive corrected `final` events (+ `corrections`).
#
# Usage:
#   scripts/stt-serve-laya.sh                     # kroko-es + Laya, rewrites
#   scripts/stt-serve-laya.sh --dry-run           # proposals only (corrections)
#   scripts/stt-serve-laya.sh --engine sherpa      # kroko EN instead of ES
#   scripts/stt-serve-laya.sh --listen 127.0.0.1:4719   # loopback only
#
# Stop: kill $(cat var/tmp/laya/serve_live.pid) $(cat var/tmp/laya/laya_serve.pid)
#       (or kill $(pgrep -x sttd))
# Judge/model install: sh scripts/fetch-laya.sh   (once; MODELOS §6.3)
# Validated config (MODELOS §6.4.1): lexical-neighbour candidates + left
# context + per-slot + gate p>=0.7; confusion-set class stays excluded.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

LAYA=var/tmp/ggmlc/build/examples/laya/laya
MULTI=var/models/laya-multilingual/laya_multilingual_q8_0.gguf
CANDIDATES=config/candidates-es.json
JUDGE_PORT=8092
LISTEN=0.0.0.0:4719
ENGINE=sherpa-es
REWRITE=--rewrite

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case $1 in
        --dry-run) REWRITE=""; shift ;;
        --engine)  ENGINE=${2:?--engine needs a value}; shift 2 ;;
        --listen)  LISTEN=${2:?--listen needs a value}; shift 2 ;;
        --judge-port) JUDGE_PORT=${2:?--judge-port needs a value}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "stt-serve-laya: unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -x "$LAYA" ]   || { echo "stt-serve-laya: judge binary missing — run: sh scripts/fetch-laya.sh" >&2; exit 1; }
[ -f "$MULTI" ]  || { echo "stt-serve-laya: model missing — run: sh scripts/fetch-laya.sh" >&2; exit 1; }
[ -f "$CANDIDATES" ] || { echo "stt-serve-laya: missing $CANDIDATES" >&2; exit 1; }
mkdir -p var/tmp/laya var/tmp/serve

# 1) Laya judge (idempotent: only if not already answering)
if curl -sf -m 2 "http://127.0.0.1:$JUDGE_PORT/health" >/dev/null 2>&1; then
    echo "stt-serve-laya: judge already up on :$JUDGE_PORT"
else
    echo "stt-serve-laya: starting Laya judge on :$JUDGE_PORT"
    nohup "$LAYA" serve "$MULTI" --port "$JUDGE_PORT" \
        > var/tmp/laya/laya_serve.log 2>&1 &
    echo $! > var/tmp/laya/laya_serve.pid
    i=0
    while ! curl -sf -m 2 "http://127.0.0.1:$JUDGE_PORT/health" >/dev/null 2>&1; do
        i=$((i + 1)); [ "$i" -ge 30 ] && { echo "stt-serve-laya: judge did not come up (var/tmp/laya/laya_serve.log)" >&2; exit 1; }
        sleep 1
    done
fi

# 2) server: mic -> kroko -> corrector (left context from previous finals) -> sttd
# Note: --engine only sets the hello descriptor (and enables partials for
# sherpa); the real engine is the one inside --pipeline.
echo "stt-serve-laya: engine=$ENGINE listen=$LISTEN mode=$([ -n "$REWRITE" ] && echo rewrite || echo dry-run)"
echo "stt-serve-laya: NOTE LAN bind — trusted network only (OPERACION.md §7)"
exec sh scripts/stt-serve.sh --listen "$LISTEN" --show-token --engine "$ENGINE" \
    --pipeline "scripts/stt-mic.sh --engine $ENGINE | python3 -u scripts/stt-correct.py \
        --ndjson --sources lexical-neighbour --candidates $CANDIDATES \
        --context 1 --per-slot --gate-p 0.7 --gate-margin 0.2 $REWRITE \
        --decisions var/tmp/laya/live_dec.ndjson"
