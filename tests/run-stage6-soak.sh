#!/bin/sh
# Stage 6 soak — S6.6: 30 min with a connected client, stable sttd RSS, no
# connection/slot leaks (PROGRESO S6.6, REGLAS R11: the full soak is a
# release gate, not a per-change check).
#
#   sh tests/run-stage6-soak.sh --quick      # 3 min (iteration)
#   sh tests/run-stage6-tests.sh              # (full 30 min is the release gate)
#   sh tests/run-stage6-soak.sh --self-test   # offline leak-metric check
#
# Microphone-free and deterministic: the server is the real ops entrypoint
# scripts/stt-serve.sh (single instance, cleanup traps — exercised here as
# shipped) with a paced fixture pipeline instead of the mic:
#
#   fixture: python3 emitter at ~2 events/s — one `start`, then alternating
#   partial/final, and a fresh `start` (new session id in the hello replay)
#   every 5 min (60 s in --quick) to exercise the session cycle. Mid-soak
#   session boundaries do NOT emit `eof`: the contract (§9.3) closes every
#   client at eof and one client must stay connected the whole time; the
#   single final `eof` ends the soak and closes the clients with 1000.
#
#   clients: one long-lived ws_probe.py collect (connects before the first
#   event, gates the fixture via --ready-file + trigger file, stays until
#   the final eof) + a churn client connecting/disconnecting every 30 s.
#
# Assertions (stability, never wall-clock precision):
#   1. the long-lived client's event stream is VERBATIM equal to the
#      fixture's emitted log (no gaps, no duplicates, no reordering);
#      event count matches the fixture cadence (loose bounds).
#   2. sttd RSS sampled every 10 s: LEAK detection, not warm-up policing.
#      The Go heap RSS is a GC sawtooth, so single endpoint samples are
#      noise: the leak gate is the TREND -- a least-squares fit over the
#      SECOND HALF of the samples (slope <= 10 kB/min; x = sample index x
#      the 10 s nominal cadence, never the unix-ts column: CLOCK_REALTIME
#      steps on this device) plus an absolute < 64 MB guard. The endpoint
#      delta (warm-up end vs last) and first-half growth are INFO only
#      (spec H: the old endpoint gate compared two single sawtooth samples
#      and failed a run whose second-half trend was -72 kB/min = no leak).
#      Windowed medians ([25 %, 35 %) vs last 15 %) are INFO. NOTE
#      --quick: the Go heap warm-up (~16 min observed) outlasts the 3-min
#      window, so there the warm-up covers the whole series, the trend
#      gate is trivially true, and leak detection remains the full soak's
#      job (R11); the 64 MB guard still applies in every mode. --self-test
#      validates the metric offline: the real rss.log series passes, a
#      synthetic +90 kB/min sawtoothed leak fails.
#   3. after the soak: ws_probe.py churn 30 + max_clients (8) fresh
#      simultaneous connections — slots and connections are not leaking.
#   4. scripts/stt-serve.sh stops cleanly: no stray sttd/fixture processes.
#
# No sleep-as-synchronization: every wait is a bounded wait for observable
# state (log lines, files, pid liveness). Pacing sleeps (fixture cadence,
# churn period, RSS period) are the load, not synchronization.
#
# Artifacts in var/tmp/stage6-soak/: soak-run.log (metrics table),
# soak-summary.json (written on success AND on failure), emit.ndjson,
# emit-report.json, client.json, churn.log, rss.log, serve.out.log,
# churn-post.json, asserts.ndjson (one JSON line per assertion result).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
STTD="$ROOT/var/bin/sttd"
SERVE="$ROOT/scripts/stt-serve.sh"
PROBE="$ROOT/tests/ws_probe.py"
T="$ROOT/var/tmp/stage6-soak"
FIX="$T/fix"
LOG="$T/soak-run.log"
SUMMARY="$T/soak-summary.json"

DUR=1800
SESSION_EVERY=300
RATE=2
MAXC=8

usage() {
	sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
}

# rss_analyze RSS_FILE DURATION_S -- one line of RSS metrics:
#   first warmup_end last max min n mid growth1 trend2 trivial med_warmup med_last
# Shared by the soak assertion and --self-test (single source of truth for
# the leak metric). The trend x-axis is the sample index * 10 s nominal
# cadence, NEVER the unix-ts column (CLOCK_REALTIME steps on this device).
rss_analyze() {
	python3 - "$1" "$2" <<'PY'
import sys
vals = [int(p[1]) for p in (l.split() for l in open(sys.argv[1]))
        if len(p) == 2 and p[1].isdigit()]
dur = int(sys.argv[2])
n = len(vals)
if not n:
    raise SystemExit  # no samples: caller fails with its own message
w = n // 4                            # 25 % warm-up (release soak)
if dur <= 180:                        # --quick: warm-up outlasts the
    w = n - 1                         # 3-min window (RSS still stepping
# at 180 s; ~16 min to peak in the full run), so a kB plateau there can
# only re-measure warm-up -- flaky by construction. The trend gate is
# trivially true and leak detection stays the 30-min release soak's
# job (R11); the 64 MB absolute guard still applies in every mode.
h = n // 2
xs = [i * 10.0 for i in range(h, n)]  # nominal cadence, not wall time
ys = vals[h:]
mx = sum(xs) / len(xs); my = sum(ys) / len(ys)
num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
den = sum((x - mx) ** 2 for x in xs)
trend = num / den * 60.0 if den else 0.0
def med(a):
    a = sorted(a)
    m = len(a)
    return round(a[m // 2]) if m % 2 else round((a[m // 2 - 1] + a[m // 2]) / 2.0)
lo, hi = int(n * 0.25), max(int(n * 0.35), int(n * 0.25) + 1)  # [25 %, 35 %)
k = min(int(n * 0.85), n - 1)                                   # last 15 %
print(vals[0], vals[w], vals[-1], max(vals), min(vals), n,
      vals[h], vals[h] - vals[0], round(trend, 2),
      1 if w >= n - 1 else 0, med(vals[lo:hi]), med(vals[k:]))
PY
}

self_test() { # --self-test: offline validation of the leak metric.
	# (a) the REAL series from the last soak's rss.log must PASS the trend
	#     assertion (the 18:34 run's endpoint gate failed it while its
	#     second-half trend was negative); (b) a synthetic leak must FAIL.
	_lim=10 _rc=0
	if [ -s "$T/rss.log" ]; then
		set -- $(rss_analyze "$T/rss.log" 1800)
		if [ -n "$9" ] && awk -v t="$9" -v lim="$_lim" 'BEGIN { exit !(t <= lim) }'; then
			echo "self-test PASS: real rss.log series (n=$6 samples) passes: second-half trend $9 kB/min <= ${_lim} kB/min (meds ${11} -> ${12} kB)"
		else
			echo "self-test FAIL: real rss.log series (n=$6) trend $9 kB/min > ${_lim} kB/min"
			_rc=1
		fi
	else
		echo "self-test SKIP: $T/rss.log not found (run a soak first)"
		_rc=1
	fi
	_leak="$T/selftest-leak.rss"
	awk 'BEGIN { for (i = 0; i < 181; i++) {
		saw = (i % 7 < 4) ? 300 : -300
		printf "%d %d\n", 1700000000 + i * 10, 6544 + i * 15 + saw
	} }' >"$_leak"
	set -- $(rss_analyze "$_leak" 1800)
	if [ -n "$9" ] && awk -v t="$9" -v lim="$_lim" 'BEGIN { exit !(t > lim) }'; then
		echo "self-test PASS: synthetic leak (6544 + 90 kB/min, sawtooth +/-300 kB, $6 samples) FAILS the assertion: trend +$9 kB/min > ${_lim} kB/min"
	else
		echo "self-test FAIL: synthetic leak not detected (trend $9 kB/min)"
		_rc=1
	fi
	return "$_rc"
}

case "${1:-}" in
	"") ;;
	--quick) DUR=180; SESSION_EVERY=60 ;;
	--self-test) mkdir -p "$T"; self_test; exit $? ;;
	-h|--help) usage; exit 0 ;;
	*) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac
MODE=full
[ "$DUR" = 180 ] && MODE=quick

# soak-summary.json bookkeeping: the summary is written on success AND on
# every failure path (S6.6 lesson: a FAILed 30-min run left no summary).
# Defaults keep write_summary meaningful before the soak produces data.
RSS_FIRST=0 RSS_WARMUP_END=0 RSS_LAST=0 RSS_MAX=0 RSS_MIN=0 N_RSS=0
RSS_MID=0 RSS_GROWTH1=0 RSS_TREND2=0 RSS_MED_W=0 RSS_MED_L=0 TREND_LIMIT=10
N_EMIT=0 N_CLI=0 SESSIONS=0 CLOSE_CODE=0

arec() { # NAME OK DETAIL -- append one assertion result to asserts.ndjson.
	jq -cn --arg name "$1" --argjson ok "$2" --arg detail "$3" \
		'{name: $name, ok: $ok, detail: $detail}' >>"$ASSERTS" || true
}

write_summary() { # STATUS NOTE -> soak-summary.json (best effort, never fatal).
	_st=$1 _note=$2
	_a="$ASSERTS"; [ -s "$_a" ] || _a=/dev/null
	_cp="$CHURNPOST"; [ -s "$_cp" ] || _cp=/dev/null
	# Churn numbers are computed FROM THE FILES at write time (spec H): a
	# mid-sequence fail() used to see the pre-tally zeroed counters. cycles
	# = the churn client's own 'done N' (attempted cycles if it never
	# finished); failures = FAIL lines in churn.log.
	_cn=$(sed -n 's/.* done //p' "$CHURN" 2>/dev/null | tail -n 1)
	[ -n "$_cn" ] || { _cn=$(grep -c ' cycle ' "$CHURN" 2>/dev/null) || _cn=0; }
	_cf=$(grep -c 'FAIL' "$CHURN" 2>/dev/null) || _cf=0
	jq -n \
		--arg status "$_st" --arg note "$_note" \
		--arg mode "$MODE" --argjson duration_s "$DUR" --arg url "${URL:-}" \
		--argjson rss_samples "$N_RSS" \
		--argjson rss_first_kb "$RSS_FIRST" --argjson rss_warmup_end_kb "$RSS_WARMUP_END" \
		--argjson rss_last_kb "$RSS_LAST" --argjson rss_max_kb "$RSS_MAX" \
		--argjson rss_min_kb "$RSS_MIN" \
		--argjson rss_first_half_growth_kb "$RSS_GROWTH1" \
		--argjson rss_second_half_trend_kb_per_min "$RSS_TREND2" \
		--argjson rss_endpoint_delta_kb "$((RSS_LAST - RSS_WARMUP_END))" \
		--argjson rss_med_warmup_kb "$RSS_MED_W" --argjson rss_med_last_kb "$RSS_MED_L" \
		--argjson plateau_limit_kb 512 --argjson trend_limit_kb_per_min "$TREND_LIMIT" \
		--argjson rss_absolute_limit_kb 65536 \
		--argjson events_emitted "$N_EMIT" --argjson events_client "$N_CLI" \
		--argjson sessions "$SESSIONS" --argjson close_code "$CLOSE_CODE" \
		--argjson churn_cycles "$_cn" --argjson churn_failures "$_cf" \
		--argjson max_clients "$MAXC" \
		--rawfile asserts "$_a" --slurpfile churn_post "$_cp" \
		'{status: $status, note: $note, mode: $mode, duration_s: $duration_s,
		  url: $url, rss_samples: $rss_samples,
		  rss_first_kb: $rss_first_kb, rss_warmup_end_kb: $rss_warmup_end_kb,
		  rss_last_kb: $rss_last_kb, rss_max_kb: $rss_max_kb,
		  rss_min_kb: $rss_min_kb,
		  rss_first_half_growth_kb: $rss_first_half_growth_kb,
		  rss_second_half_trend_kb_per_min: $rss_second_half_trend_kb_per_min,
		  rss_endpoint_delta_kb: $rss_endpoint_delta_kb,
		  rss_med_warmup_kb: $rss_med_warmup_kb, rss_med_last_kb: $rss_med_last_kb,
		  plateau_limit_kb: $plateau_limit_kb,
		  trend_limit_kb_per_min: $trend_limit_kb_per_min,
		  rss_absolute_limit_kb: $rss_absolute_limit_kb,
		  events_emitted: $events_emitted, events_client: $events_client,
		  events_identical: ($events_emitted == $events_client and $events_emitted > 0),
		  sessions: $sessions, close_code: $close_code,
		  clients: {long_lived: 1, churn_cycles: $churn_cycles,
		            churn_failures: $churn_failures, max_clients: $max_clients,
		            churn_post_cycles: ($churn_post[0].cycles // null),
		            churn_post_fresh_ok: ($churn_post[0].fresh_ok // null)},
		  churn_post: (if ($churn_post | length) > 0
		               then $churn_post[0] | {cycles, fresh_ok, rss_before_kb, rss_after_kb}
		               else null end),
		  assertions: ($asserts | split("\n") | map(select(length > 0) | fromjson))}' \
		>"$SUMMARY" 2>/dev/null || true
}

need() { [ -e "$1" ] || fail "missing $1 (run: make core / make adapters)"; }
fail() {
	write_summary failed "$*" || true
	echo "FAIL: $*" >&2
	echo "FAIL: $*" >>"$LOG" 2>/dev/null || true
	exit 1
}
log() { echo "$*" | tee -a "$LOG"; }

EMIT="$T/emit.ndjson"
REPORT="$T/emit-report.json"
CLIENT="$T/client.json"
CLIENT_ERR="$T/client.err"
CHURN="$T/churn.log"
RSS="$T/rss.log"
SERVEOUT="$T/serve.out.log"
CHURNPOST="$T/churn-post.json"
ASSERTS="$T/asserts.ndjson"
TRIGGER="$T/emit.trigger"
READY="$T/client.ready"

rm -f "$LOG" "$EMIT" "$REPORT" "$CLIENT" "$CLIENT_ERR" "$CHURN" "$RSS" \
	"$SERVEOUT" "$CHURNPOST" "$TRIGGER" "$READY" "$SUMMARY" "$ASSERTS"
mkdir -p "$T" "$FIX"

need "$STTD"; need "$SERVE"; need "$PROBE"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v timeout >/dev/null 2>&1 || fail "timeout(1) not found"

GRACE=10
SERVE_PID=; CLIENT_PID=; CHURN_PID=; RSS_PID=; STTD_PID=

# sweep_fixtures — kill leftover processes spawned from $FIX (matched on
# /proc/*/cmdline; scoped to this soak's paths so a concurrent
# run-stage6-tests.sh server is never touched).
sweep_fixtures() {
	python3 - "$FIX" <<'SWEEP' >>"$LOG" 2>&1
import os, signal, sys
fix = sys.argv[1]
found = []
for entry in os.listdir("/proc"):
    if not entry.isdigit():
        continue
    pid = int(entry)
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            cmd = f.read().replace(b"\x00", b" ").decode("utf-8", "replace")
    except OSError:
        continue
    if fix in cmd:
        found.append((pid, cmd[:80]))
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
for pid, cmd in found:
    print("cleanup: killed leftover fixture pid %d (%s)" % (pid, cmd))
sys.exit(1 if found else 0)
SWEEP
}

cleanup() {
	_rc=$?
	trap - EXIT INT TERM
	if [ -n "${SERVE_PID:-}" ]; then
		kill -TERM "$SERVE_PID" 2>/dev/null || true
	fi
	for _p in "${CLIENT_PID:-}" "${CHURN_PID:-}" "${RSS_PID:-}"; do
		[ -n "$_p" ] && kill -TERM "$_p" 2>/dev/null || true
	done
	_d=0
	while [ "$_d" -lt $((GRACE * 10)) ]; do
		_alive=""
		[ -n "${SERVE_PID:-}" ] && kill -0 "$SERVE_PID" 2>/dev/null && _alive="$_alive $SERVE_PID"
		[ -z "$_alive" ] && break
		sleep 0.1
		_d=$((_d + 1))
	done
	for _p in $_alive; do
		kill -KILL "$_p" 2>/dev/null || true
	done
	sweep_fixtures || true
	if [ "$_rc" -ne 0 ] && [ ! -s "$SUMMARY" ]; then
		write_summary aborted "interrupted (rc=$_rc)" || true
	fi
	exit "$_rc"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

# -- bounded waits for observable state -------------------------------------

wait_file() { # FILE TIMEOUT_S LABEL
	_f=$1 _t=$2 _l=$3 _d=0
	while [ ! -e "$_f" ]; do
		if [ "$_d" -ge $((_t * 20)) ]; then
			fail "timeout (${_t}s) waiting for $_l ($_f)"
		fi
		sleep 0.05
		_d=$((_d + 1))
	done
}

wait_grep() { # FILE PATTERN TIMEOUT_S LABEL
	_f=$1 _p=$2 _t=$3 _l=$4 _d=0
	while ! grep -Eq "$_p" "$_f" 2>/dev/null; do
		if [ "$_d" -ge $((_t * 20)) ]; then
			fail "timeout (${_t}s) waiting for $_l (pattern '$_p' in $_f)"
		fi
		sleep 0.05
		_d=$((_d + 1))
	done
}

wait_lines() { # FILE MIN TIMEOUT_S LABEL
	_f=$1 _m=$2 _t=$3 _l=$4 _d=0
	while [ "$(wc -l <"$_f" 2>/dev/null || echo 0)" -lt "$_m" ]; do
		if [ "$_d" -ge $((_t * 20)) ]; then
			fail "timeout (${_t}s) waiting for $_l (>= ${_m} lines in $_f)"
		fi
		sleep 0.05
		_d=$((_d + 1))
	done
}

wait_dead() { # PID TIMEOUT_S LABEL
	_p=$1 _t=$2 _l=$3 _d=0
	while kill -0 "$_p" 2>/dev/null; do
		if [ "$_d" -ge $((_t * 20)) ]; then
			fail "timeout (${_t}s) waiting for $_l (pid $_p still alive)"
		fi
		sleep 0.05
		_d=$((_d + 1))
	done
}

# -- fixture emitter (paced stt-events/1 source, see header) ----------------

cat >"$FIX/emit.py" <<'EOF'
#!/usr/bin/env python3
"""Paced stt-events/1 emitter -- Stage 6 soak fixture (S6.6).

Gates on --trigger (the harness touches it once the long-lived WS client is
connected, so every emitted event is post-connect and the count check is
exact), then emits ~--rate events/s: one `start`, then alternating
partial/final, with a fresh `start` every --session-every seconds (a new
session id in sttd's hello replay). Session boundaries mid-soak do NOT emit
`eof`: contract 9.3 closes every connected client at eof and the soak needs
one client connected for the whole duration; the single final `eof` ends
the soak and closes the clients with 1000. The trigger wait is unbounded on
purpose: a supervisor restart of this command must idle at the gate instead
of crash-looping (the consumed trigger is never re-emitted). Every emitted
line is mirrored to --log (line-buffered) for the verbatim no-gaps diff."""
import argparse, json, os, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("--trigger", required=True)
ap.add_argument("--log", required=True)
ap.add_argument("--report", required=True)
ap.add_argument("--duration", type=float, required=True)
ap.add_argument("--rate", type=float, default=2.0)
ap.add_argument("--session-every", type=float, default=300.0)
a = ap.parse_args()

while not os.path.exists(a.trigger):
    time.sleep(0.05)
os.unlink(a.trigger)  # consume: a restarted emitter re-gates, never re-emits

log = open(a.log, "w", buffering=1)

def emit(ev):
    line = json.dumps(ev, separators=(",", ":"))
    sys.stdout.write(line + "\n")
    sys.stdout.flush()
    log.write(line + "\n")

audio = {"rate": 16000, "channels": 1, "format": "s16le"}
period = 1.0 / a.rate
start = time.monotonic()
end = start + a.duration
events = 0
sessions = 1
next_session = a.session_every
tick = 0
try:
    while True:
        due = start + tick * period
        if due >= end:
            break
        delay = due - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        t = tick * period
        if tick == 0 or t >= next_session:
            if tick > 0:
                sessions += 1
                next_session += a.session_every
            emit({"type": "start", "audio": audio})
        elif events % 2 == 1:
            emit({"type": "partial", "text": "soak partial #%d" % tick,
                  "t0": round(t, 3), "t1": round(t + 0.5, 3)})
        else:
            emit({"type": "final", "text": "soak final #%d" % tick,
                  "t0": round(t, 3), "t1": round(t + 1.0, 3),
                  "model": "soak-fixture", "rtf": 0.01})
        events += 1
        tick += 1
except KeyboardInterrupt:
    sys.exit(130)
emit({"type": "eof", "frames": events, "audio_s": round(a.duration, 1)})
events += 1
log.close()
with open(a.report, "w") as f:
    json.dump({"events": events, "sessions": sessions,
               "duration_s": round(time.monotonic() - start, 1),
               "rate": a.rate, "session_every_s": a.session_every}, f)
EOF

# -- run ---------------------------------------------------------------------

log "== stage6 soak: mode=$MODE duration=${DUR}s rate=${RATE}/s session-every=${SESSION_EVERY}s max_clients=$MAXC"
log "started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

TOK=$("$STTD" --print-token)

# The server under test is the ops entrypoint itself (single-instance
# takeover, wakelock skip, cleanup traps -- all as shipped).
: >"$SERVEOUT"
sh "$SERVE" --max-clients "$MAXC" --no-wakelock \
	--pipeline "python3 $FIX/emit.py --trigger $TRIGGER --log $EMIT --report $REPORT --duration $DUR --rate $RATE --session-every $SESSION_EVERY" \
	>"$SERVEOUT" 2>&1 &
SERVE_PID=$!
log "stt-serve pid $SERVE_PID"
wait_grep "$SERVEOUT" 'listening on ws://' 30 'stt-serve startup'
ADDR=$(sed -n 's|^stt-serve: listening on ws://\([^/]*\)/v1/feed.*|\1|p' "$SERVEOUT" | tail -n 1)
URL="ws://$ADDR/v1/feed"
wait_file "$ROOT/var/tmp/serve/sttd.pid" 10 'sttd pidfile'
STTD_PID=$(cat "$ROOT/var/tmp/serve/sttd.pid")
log "server up: $URL (sttd pid $STTD_PID)"

python3 - "$ADDR" <<'PY' >>"$LOG" 2>&1 || fail "healthz did not come up"
import sys, time, urllib.request
addr = sys.argv[1]
end = time.monotonic() + 15
while time.monotonic() < end:
    try:
        print("healthz:", urllib.request.urlopen(
            "http://%s/healthz" % addr, timeout=2).read().decode())
        sys.exit(0)
    except Exception:
        time.sleep(0.1)
sys.exit(1)
PY

# Long-lived client: connects BEFORE any event exists (the fixture is still
# gated), so every emitted event must reach it. --ready-file gates the
# fixture trigger below (no sleep-based ordering).
timeout $((DUR + 150)) python3 "$PROBE" collect "$URL" --token "$TOK" \
	--require-eof --timeout $((DUR + 90)) --ready-file "$READY" \
	>"$CLIENT" 2>"$CLIENT_ERR" &
CLIENT_PID=$!
wait_file "$READY" 20 'long-lived client connected'

# Churn client: one connect/read-hello/disconnect every 30 s until the
# fixture reports (its monotonic deadline is the clock authority; a cycle
# bound keeps the loop finite if the fixture dies). Load, not a check:
# failures are asserted from the log afterwards. NOTE: no wall-clock
# deadlines — this device's CLOCK_REALTIME steps with NTP.
: >"$CHURN"
(
	_n=0
	_max=$((DUR / 30 + 4))
	while [ ! -f "$REPORT" ] && [ "$_n" -lt "$_max" ]; do
		_n=$((_n + 1))
		if timeout 15 python3 "$PROBE" collect "$URL" --token "$TOK" \
			--expect 1 --timeout 10 >/dev/null 2>&1; then
			echo "$(date +%s) cycle $_n ok" >>"$CHURN"
		else
			echo "$(date +%s) cycle $_n FAIL" >>"$CHURN"
		fi
		sleep 30
	done
	echo "$(date +%s) done $_n" >>"$CHURN"
) &
CHURN_PID=$!

# Fixture go. Warm-up (observable): >= 2 events flowing + first churn cycle.
: >"$EMIT"
touch "$TRIGGER"
wait_lines "$EMIT" 2 20 'first fixture events'
wait_grep "$CHURN" ' cycle 1 ok' 30 'first churn cycle (warm-up)'

# RSS sampler: every 10 s from warm-up until the fixture report exists
# (the emitter's monotonic deadline is the soak duration; the sample bound
# keeps the loop finite if the fixture dies — never wall clock, see above).
: >"$RSS"
(
	_s=0
	_max=$((DUR / 10 + 12))
	while [ ! -f "$REPORT" ] && [ "$_s" -lt "$_max" ]; do
		_r=$(awk '/^VmRSS:/ {print $2}' "/proc/$STTD_PID/status" 2>/dev/null) || _r=
		if [ -n "$_r" ]; then
			echo "$(date +%s) $_r" >>"$RSS"
		fi
		_s=$((_s + 1))
		[ -f "$REPORT" ] && break
		sleep 10
	done
	_r=$(awk '/^VmRSS:/ {print $2}' "/proc/$STTD_PID/status" 2>/dev/null) || _r=
	if [ -n "$_r" ]; then
		echo "$(date +%s) $_r" >>"$RSS"
	fi
	echo "rss-done" >>"$RSS"
) &
RSS_PID=$!

log "soak running: events flowing, long-lived client connected, churn every 30 s, RSS every 10 s"

# The soak duration is the subject: wait for the client to finish (the
# final eof closes it with 1000). Bounded by the timeout wrapper.
wait "$CLIENT_PID" || fail "long-lived client failed: $(tail -c 300 "$CLIENT_ERR" 2>/dev/null)"
wait_file "$REPORT" 30 'fixture report'
wait_grep "$CHURN" ' done ' 150 'churn loop done'
wait_grep "$RSS" '^rss-done$' 60 'rss sampler done'
log "soak wall time reached: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# -- assertions ---------------------------------------------------------------

log ""
log "== assertions =="

# 1. Client stream: hello first, closed 1000 by the final eof, and VERBATIM
#    equal to the fixture log (no gaps, no duplicates, no reordering).
CLOSE_CODE=$(jq -r '.close // 0' "$CLIENT" 2>/dev/null) || CLOSE_CODE=0
jq -e '.close == 1000' "$CLIENT" >/dev/null || {
	arec event_stream false "close code ${CLOSE_CODE} != 1000"
	fail "long-lived client close != 1000: $(jq -c '{close, reason}' "$CLIENT")"
}
jq -e '.messages[0] | fromjson | .type == "hello"' "$CLIENT" >/dev/null || {
	arec event_stream false "first client message is not hello"
	fail "first client message is not hello"
}
jq -Rs 'split("\n") | map(select(length > 0))' "$EMIT" >"$T/emit.arr.json"
jq -c '.messages[1:]' "$CLIENT" >"$T/client.events.json"
N_EMIT=$(jq 'length' "$T/emit.arr.json")
N_CLI=$(jq 'length' "$T/client.events.json")
jq -e -n --slurpfile e "$T/emit.arr.json" --slurpfile c "$T/client.events.json" \
	'($e[0] | length) > 0 and ($e[0] == $c[0])' >/dev/null || {
	arec event_stream false "client stream != fixture stream ($N_CLI vs $N_EMIT events)"
	fail "client stream != fixture stream ($N_CLI vs $N_EMIT events): gaps/duplicates/reorder"
}
log "OK event stream: $N_CLI/$N_EMIT events verbatim, hello first, close 1000"
arec event_stream true "$N_CLI/$N_EMIT events verbatim, hello first, close 1000"

# 2. Cadence sanity (loose bounds on counts, never wall-clock precision).
EXP_EVENTS=$(jq -r '.events' "$REPORT")
SESSIONS=$(jq -r '.sessions' "$REPORT")
awk -v got="$EXP_EVENTS" -v want=$((DUR * RATE)) 'BEGIN {
	if (got < want * 0.9 || got > want + 10) exit 1 }' || {
	arec fixture_cadence false "$EXP_EVENTS events, want ~$((DUR * RATE))"
	fail "fixture cadence off: $EXP_EVENTS events, want ~$((DUR * RATE))"
}
log "OK fixture cadence: $EXP_EVENTS events (~${RATE}/s for ${DUR}s), $SESSIONS sessions"
arec fixture_cadence true "$EXP_EVENTS events (~${RATE}/s for ${DUR}s), $SESSIONS sessions"

# 3. RSS leak detection (NOT warm-up policing): the gate is the TREND of
#    the second half of the samples (least-squares slope <= 10 kB/min over
#    x = sample index * 10 s nominal cadence -- NEVER the unix-ts column:
#    CLOCK_REALTIME steps on this device, observed mid-run steps of
#    +39/+128/+265 s in a real soak). Endpoint delta and first-half growth
#    are INFO only (spec H: comparing two single samples of the Go GC
#    sawtooth failed a -72 kB/min run). 64 MB absolute guard stays.
set -- $(rss_analyze "$RSS" "$DUR")
RSS_FIRST=$1 RSS_WARMUP_END=$2 RSS_LAST=$3 RSS_MAX=$4 RSS_MIN=$5
N_RSS=$6 RSS_MID=$7 RSS_GROWTH1=$8 RSS_TREND2=$9 RSS_TRIVIAL=${10}
RSS_MED_W=${11} RSS_MED_L=${12}
[ -n "$RSS_FIRST" ] && [ "$RSS_FIRST" != "0" ] || fail "no RSS samples in $RSS"
[ "$N_RSS" -ge 5 ] || fail "only $N_RSS RSS samples (want >= 5)"
RSS_DELTA=$((RSS_LAST - RSS_WARMUP_END))
if [ "$RSS_TRIVIAL" != "1" ] && \
	awk -v t="$RSS_TREND2" -v lim="$TREND_LIMIT" 'BEGIN { exit !(t > lim) }'; then
	arec rss_leak_trend false "second-half trend +${RSS_TREND2} kB/min > ${TREND_LIMIT} kB/min"
	log "possible leak: +${RSS_TREND2} kB/min in the second half (rss ${RSS_FIRST} -> ${RSS_WARMUP_END} -> ${RSS_LAST} kB, max ${RSS_MAX} kB)"
	fail "sttd RSS second-half trend +${RSS_TREND2} kB/min > ${TREND_LIMIT} kB/min (leak?)"
fi
if [ "$RSS_TRIVIAL" = "1" ]; then
	arec rss_leak_trend true "trivial: warm-up covers the whole ${DUR}s quick soak (leak gate = full 30-min soak); trend ${RSS_TREND2} kB/min, max ${RSS_MAX} kB recorded as INFO"
else
	arec rss_leak_trend true "second-half trend ${RSS_TREND2} kB/min <= ${TREND_LIMIT} kB/min"
fi
if [ "$RSS_MAX" -ge 65536 ]; then
	arec rss_absolute false "max ${RSS_MAX} kB >= 65536 kB"
	fail "sttd RSS max ${RSS_MAX} kB >= 64 MB absolute guard"
fi
arec rss_absolute true "max ${RSS_MAX} kB < 65536 kB"
if [ "$RSS_TRIVIAL" = "1" ]; then
	log "OK RSS leak trend (trivial): warm-up covers the whole ${DUR}s quick soak (Go heap warm-up ~16 min > window; leak detection is the full 30-min soak): rss ${RSS_FIRST} -> ${RSS_LAST} kB, max ${RSS_MAX} kB < 65536 kB, $N_RSS samples"
else
	log "OK RSS leak trend: second half ${RSS_TREND2} kB/min <= ${TREND_LIMIT} kB/min, max ${RSS_MAX} kB < 65536 kB, min ${RSS_MIN} kB, $N_RSS samples"
fi
log "INFO RSS endpoints (not asserted, GC sawtooth noise): warm-up end ${RSS_WARMUP_END} -> last ${RSS_LAST} kB (+${RSS_DELTA} kB vs plateau_limit 512 kB); first half: +${RSS_GROWTH1} kB (${RSS_FIRST} -> ${RSS_MID} kB)"
log "INFO RSS medians: warm-up window [25%,35%) ${RSS_MED_W} kB vs last 15% ${RSS_MED_L} kB"

# 4. Churn during the soak: every cycle must have succeeded. write_summary
#    parses the SAME log at write time, so summary churn_cycles is by
#    construction what the churn client logged ('done N').
CHURN_N=$(sed -n 's/.* done //p' "$CHURN" | tail -n 1)
CHURN_FAILS=$(grep -c 'FAIL' "$CHURN" || true)
[ "$CHURN_FAILS" = "0" ] || {
	arec churn_soak false "$CHURN_FAILS churn cycles failed during the soak"
	fail "$CHURN_FAILS churn cycles failed during the soak (see $CHURN)"
}
CHURN_MIN=$((DUR / 30 - 2))
[ "$CHURN_N" -ge "$CHURN_MIN" ] || {
	arec churn_soak false "only $CHURN_N churn cycles (< $CHURN_MIN) in ${DUR}s"
	fail "only $CHURN_N churn cycles (< $CHURN_MIN) in ${DUR}s"
}
log "OK churn during soak: $CHURN_N/$CHURN_MIN+ connect/disconnect cycles, 0 failures (summary churn_cycles = churn.log 'done $CHURN_N')"
arec churn_soak true "$CHURN_N/$CHURN_MIN+ cycles, 0 failures (from churn.log done $CHURN_N)"

# 5. After the soak: churn 30 + max_clients fresh SIMULTANEOUS connections
#    (slots released; no connection leak).
timeout 120 python3 "$PROBE" churn "$URL" --churn 30 --expect "$MAXC" \
	--token "$TOK" --pid "$STTD_PID" >"$CHURNPOST" 2>>"$LOG" || {
	arec churn_post false "post-soak churn command failed"
	fail "post-soak churn failed: $(cat "$CHURNPOST" 2>/dev/null)"
}
jq -e ".fresh_ok == $MAXC and .cycles == 30" "$CHURNPOST" >/dev/null || {
	arec churn_post false "$(cat "$CHURNPOST" 2>/dev/null)"
	fail "post-soak churn report: $(cat "$CHURNPOST")"
}
log "OK post-soak: 30 churn cycles + $MAXC/$MAXC fresh simultaneous clients, sttd RSS $(jq -r .rss_before_kb "$CHURNPOST") -> $(jq -r .rss_after_kb "$CHURNPOST") kB"
arec churn_post true "30 cycles + $MAXC/$MAXC fresh simultaneous clients"

# 6. Clean shutdown of the ops entrypoint: no stray sttd/fixture processes.
kill -TERM "$SERVE_PID" 2>/dev/null || true
wait_dead "$SERVE_PID" 25 'stt-serve.sh exit'
SERVE_PID=
wait_dead "$STTD_PID" 15 'sttd exit'
if sweep_fixtures; then
	arec shutdown false "leftover fixture processes after shutdown"
	fail "leftover fixture processes after shutdown (see $LOG)"
fi
log "OK shutdown: stt-serve.sh + sttd exited, no stray processes"
arec shutdown true "stt-serve.sh + sttd exited, no stray processes"

# -- summary ------------------------------------------------------------------

write_summary ok "all assertions passed"
[ -s "$SUMMARY" ] || fail "could not write $SUMMARY"

log ""
log "== RSS series (unix_ts rss_kb, every 10 s) =="
awk 'NF == 2 { print "  " $0 }' "$RSS" | tee -a "$LOG"
log ""
log "== summary ($(cat "$SUMMARY" | tr -d '\n'))"
log ""
log "SOAK OK ($MODE, ${DUR}s)"
