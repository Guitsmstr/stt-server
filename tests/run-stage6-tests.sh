#!/bin/sh
# Stage 6 checks — S6.2 smoke, S6.3 end-to-end fan-out, S6.4 security
# (docs/CONTRATOS.md §9, PROGRESO.md S6.2/S6.3/S6.4).
#
# Requires: make (var/bin/stt + var/bin/sttd), make adapters, jq, sox,
# python3 (stdlib only), timeout(1). Self-contained; ~1-2 min warm (the
# sherpa partials section loads the zipformer model once).
#
# Structure: every section starts its own sttd on a free loopback port
# (parsed from sttd's stderr; never hardcoded), drives it with fixture
# pipelines (no microphone) and asserts on the artifacts written to
# var/tmp/stage6/. All child processes are reaped by the EXIT trap
# (SIGTERM, then SIGKILL after a grace period).
#
# Determinism rules (no sleep-as-synchronization):
#   - sttd runs with STT_SERVER_DEBUG=1: it logs "client connected
#     (total N)" / "session started (id ...)" per observable state
#     change; the harness waits for those lines before touching the
#     fixture trigger files. Fixtures block on their triggers.
#   - ws_probe.py collect --ready-file gates holder clients (S6.4 503).
#   - Latency: sttd's stdout mirror is timestamped as it is read
#     (sttd_wrap.py) and the WS clients record absolute time.monotonic()
#     arrivals (sample.py, built on ws_probe.WSClient); CLOCK_MONOTONIC
#     is system-wide, so per-event deltas are comparable across
#     processes. Bound: p95 <= 20 ms over >= 20 samples (contract S6.3).
#
# Sections:
#   S6.2  --version, --print-token + token file 0600, /healthz idle,
#            lazy attach (hello with "session":null)
#   S6.3  fixture: 10 known events, 2 clients (ws_probe compare) + stdout
#            mirror identical & verbatim, eof last, close 1000; late
#            client gets hello(session)+replayed start
#   S6.3  real nucleus: paced beckett (echo adapter) through sttd; WS
#            finals == mirror finals, p95 WS-vs-mirror latency <= 20 ms
#   S6.3  partials over WS with the sherpa zipformer model (SKIP if the
#            model cache is absent — never fail)
#   S6.4  401 (no/wrong token), ?token= fallback, default bind 127.0.0.1,
#            --max-clients 2 -> 503, slow client 1013 while a healthy
#            client gets the whole stream, 20-cycle churn releases slots
#   Summary: evidence table + ALL STAGE 6 CHECKS OK

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
STT="$ROOT/var/bin/stt"
STTD="$ROOT/var/bin/sttd"
ECHO_AD="$ROOT/adapters/echo/stt-adapter-echo"
SHERPA_AD="$ROOT/adapters/sherpa/stt-adapter-sherpa"
SHERPA_MODEL="$ROOT/var/models/sherpa-zipformer-en-kroko"
BECKETT="$ROOT/tests/assets/beckett.wav"
PROBE="$ROOT/tests/ws_probe.py"
T="$ROOT/var/tmp/stage6"
LOG="$T/stage6-run.log"
FIX="$T/fix"
GRACE=8

fail() {
	echo "FAIL: $*" >&2
	echo "FAIL: $*" >>"$LOG" 2>/dev/null || true
	exit 1
}
need() { [ -e "$1" ] || fail "missing $1 (run: make / make models)"; }
log() { echo "$*"; echo "$*" >>"$LOG"; }
section() { echo >>"$LOG"; log "== $* =="; }

rm -rf "$T"
mkdir -p "$T" "$FIX"
: >"$LOG"

need "$STT"; need "$STTD"; need "$ECHO_AD"; need "$BECKETT"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v sox >/dev/null 2>&1 || fail "sox not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v timeout >/dev/null 2>&1 || fail "timeout(1) not found"

# A fixed token so 401/503 checks are reproducible (64 hex, contract §9.2).
TOK=$(printf 'f00dfeed00000000beefcafe0000c0dedeadbeef00000000cafe12345678%04d' 6 | head -c 64)
case $TOK in *[!0-9a-f]* | '') fail "fixture token is not 64 hex" ;; esac

# -- process bookkeeping ----------------------------------------------------

ALL_PIDS=""
ALL_STTD=""
# sweep_fixtures — kill any leftover fixture/pacer processes spawned from
# $FIX (matched on /proc/*/cmdline). When sttd is SIGKILLed mid-shutdown,
# os/exec's context watcher may never deliver SIGINT to the pipeline child,
# orphaning it; this sweep makes the harness leave nothing behind.
sweep_fixtures() {
	python3 - "$FIX" <<'SWEEP' >>"$LOG" 2>&1 || true
import os, signal, sys
fix = sys.argv[1]
me = os.getpid()
for entry in os.listdir("/proc"):
    if not entry.isdigit():
        continue
    pid = int(entry)
    if pid == me:
        continue
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            cmd = f.read().replace(b"\x00", b" ").decode("utf-8", "replace")
    except OSError:
        continue
    if fix in cmd:
        try:
            os.kill(pid, signal.SIGKILL)
            print("cleanup: killed leftover fixture pid %d (%s)" % (pid, cmd[:80]))
        except OSError:
            pass
SWEEP
}

cleanup() {
	_rc=$?
	trap - EXIT INT TERM
	for _p in $ALL_PIDS $ALL_STTD; do
		kill -TERM "$_p" 2>/dev/null || true
	done
	_d=0
	while [ "$_d" -lt $((GRACE * 10)) ]; do
		_alive=""
		for _p in $ALL_PIDS $ALL_STTD; do
			kill -0 "$_p" 2>/dev/null && _alive="$_alive $_p"
		done
		[ -z "$_alive" ] && break
		sleep 0.1
		_d=$((_d + 1))
	done
	for _p in $_alive; do
		kill -KILL "$_p" 2>/dev/null || true
	done
	for _p in $ALL_PIDS; do
		wait "$_p" 2>/dev/null || true
	done
	sweep_fixtures
	exit "$_rc"
}
trap cleanup EXIT INT TERM

# wait_file FILE TIMEOUT_S LABEL — bounded wait for an observable file.
wait_file() {
	_f=$1 _t=$2 _l=$3 _d=0
	while [ ! -e "$_f" ]; do
		if [ "$_d" -ge $((_t * 20)) ]; then
			fail "timeout (${_t}s) waiting for $_l ($_f)"
		fi
		sleep 0.05
		_d=$((_d + 1))
	done
}

# wait_grep FILE PATTERN TIMEOUT_S LABEL — bounded wait for a log line.
wait_grep() {
	_f=$1 _p=$2 _t=$3 _l=$4 _d=0
	while ! grep -Eq "$_p" "$_f" 2>/dev/null; do
		if [ "$_d" -ge $((_t * 20)) ]; then
			fail "timeout (${_t}s) waiting for $_l (pattern '$_p' in $_f)"
		fi
		sleep 0.05
		_d=$((_d + 1))
	done
}

# wait_grep_from FILE FROMLINE PATTERN TIMEOUT_S LABEL — as wait_grep, but
# only lines from FROMLINE on count (avoids stale matches from earlier
# phases of the same server).
wait_grep_from() {
	_f=$1 _n=$2 _p=$3 _t=$4 _l=$5 _d=0
	while ! tail -n "+$_n" "$_f" 2>/dev/null | grep -Eq "$_p"; do
		if [ "$_d" -ge $((_t * 20)) ]; then
			fail "timeout (${_t}s) waiting for $_l (pattern '$_p' in $_f from line $_n)"
		fi
		sleep 0.05
		_d=$((_d + 1))
	done
}

# start_server NAME [sttd flags...] — one sttd per section, babysat by
# sttd_wrap.py (spawns it, timestamps the stdout mirror when
# SRV_MIRROR=1, exposes its pid for churn RSS, forwards SIGTERM).
# Sets: CUR_URL (ws://ADDR/v1/feed), CUR_PID (sttd), CUR_ERR (stderr log).
# Optional env: SRV_MIRROR=1 enables STTD_MIRROR_STDOUT, SRV_DEBUG=1
# enables STT_SERVER_DEBUG (default on).
start_server() {
	CUR_NAME=$1
	shift
	CUR_ERR="$T/$CUR_NAME.stderr.log"
	CUR_PIDFILE="$T/$CUR_NAME.pid"
	: >"$CUR_ERR"
	_srv_env=""
	if [ "${SRV_MIRROR:-0}" = "1" ]; then _srv_env="$_srv_env STTD_MIRROR_STDOUT=1"; fi
	if [ "${SRV_DEBUG:-1}" = "1" ]; then _srv_env="$_srv_env STT_SERVER_DEBUG=1"; fi
	# shellcheck disable=SC2086
	env $_srv_env python3 "$FIX/sttd_wrap.py" \
		--pidfile "$CUR_PIDFILE" \
		--raw "$T/$CUR_NAME.mirror.ndjson" \
		--stamped "$T/$CUR_NAME.mirror-stamped.ndjson" \
		--timeout 400 -- "$STTD" "$@" >>"$LOG" 2>>"$CUR_ERR" &
	CUR_WRAP_PID=$!
	ALL_PIDS="$ALL_PIDS $CUR_WRAP_PID"
	wait_file "$CUR_PIDFILE" 10 "$CUR_NAME sttd pid"
	CUR_PID=$(cat "$CUR_PIDFILE")
	ALL_STTD="$ALL_STTD $CUR_PID"
	wait_grep "$CUR_ERR" 'listening on ws://' 10 "$CUR_NAME listening"
	CUR_ADDR=$(sed -n 's/.*listening on ws:\/\/\([^\/]*\)\/v1\/feed.*/\1/p' "$CUR_ERR" | tail -n 1)
	CUR_URL="ws://$CUR_ADDR/v1/feed"
	log "started sttd $CUR_NAME: ws://$CUR_ADDR/v1/feed (pid $CUR_PID)"
}

# stop_server — SIGTERM (clean sttd shutdown), bounded grace, SIGKILL.
stop_server() {
	[ -n "${CUR_WRAP_PID:-}" ] || return 0
	kill -TERM "$CUR_WRAP_PID" 2>/dev/null || true
	kill -TERM "$CUR_PID" 2>/dev/null || true
	_d=0
	while kill -0 "$CUR_WRAP_PID" 2>/dev/null && [ "$_d" -lt $((GRACE * 10)) ]; do
		sleep 0.1
		_d=$((_d + 1))
	done
	kill -KILL "$CUR_WRAP_PID" 2>/dev/null || true
	kill -KILL "$CUR_PID" 2>/dev/null || true
	wait "$CUR_WRAP_PID" 2>/dev/null || true
	CUR_WRAP_PID=""
	CUR_PID=""
}

# -- generated helpers (pure python3 stdlib) --------------------------------

# idle.py — pipeline that never emits (idle server, lazy attach).
cat >"$FIX/idle.py" <<'EOF'
#!/usr/bin/env python3
import time
while True:
    time.sleep(3600)
EOF

# events10.py T1 T2 — the S6.3 fixture: waits for T1, emits `start`, waits
# for T2, then 3 partials + 4 finals + error + eof (10 known events, in
# order). Bounded waits fail loudly.
cat >"$FIX/events10.py" <<'EOF'
#!/usr/bin/env python3
import json, os, sys, time

def wait_trigger(path, timeout=30):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if os.path.exists(path):
            return
        time.sleep(0.02)
    sys.stderr.write("events10: timeout waiting for %s\n" % path)
    sys.exit(1)

def emit(ev):
    sys.stdout.write(json.dumps(ev, separators=(",", ":")) + "\n")
    sys.stdout.flush()

t1, t2 = sys.argv[1], sys.argv[2]
sys.stderr.write("events10: waiting for %s\n" % t1)
sys.stderr.flush()
wait_trigger(t1)
os.unlink(t1)  # consume: a restarted pipeline instance must not re-emit
emit({"type": "start", "audio": {"rate": 16000, "channels": 1, "format": "s16le"}})
sys.stderr.write("events10: start emitted, waiting for %s\n" % t2)
sys.stderr.flush()
wait_trigger(t2)
os.unlink(t2)
for i in range(3):
    emit({"type": "partial", "text": "fixture partial %d" % i,
          "t0": float(i), "t1": float(i) + 0.5})
for i in range(4):
    emit({"type": "final", "text": "fixture final %d" % i, "t0": float(i),
          "t1": float(i) + 1.0, "model": "fixture", "rtf": 0.01})
emit({"type": "error", "code": "fixture_error",
      "message": "synthetic non-fatal error"})
emit({"type": "eof", "frames": 4, "audio_s": 4.0})
EOF

# flood.py TRIGGER N — S6.4 slow-client fixture: waits for TRIGGER, then
# emits start + N ~31 KB final events + eof. The event count/size must
# exceed the kernel send buffer (autotuned up to 4 MiB) plus the default
# 256-deep per-client queue, so a client that stops reading is dropped
# with 1013 by real backpressure (mirrors TestSlowClientDropped in
# core/internal/server). Lines stay under the WS library's 32 KiB read
# limit so the healthy client is unaffected.
cat >"$FIX/flood.py" <<'EOF'
#!/usr/bin/env python3
import json, os, sys, time

trigger, count = sys.argv[1], int(sys.argv[2])
end = time.monotonic() + 30
while time.monotonic() < end:
    if os.path.exists(trigger):
        os.unlink(trigger)  # consume: restarts must not re-flood
        break
    time.sleep(0.02)
else:
    sys.stderr.write("flood: timeout waiting for %s\n" % trigger)
    sys.exit(1)

def emit(ev):
    sys.stdout.write(json.dumps(ev, separators=(",", ":")) + "\n")
    sys.stdout.flush()

pad = "x" * 31000
emit({"type": "start", "audio": {"rate": 16000, "channels": 1, "format": "s16le"}})
for i in range(count):
    emit({"type": "final", "text": "flood %04d %s" % (i, pad),
          "t0": i, "t1": i + 1, "model": "flood", "rtf": 0.01})
emit({"type": "eof", "frames": count, "audio_s": float(count)})
EOF

# pace.py — paced PCM feeder (feed_stream.py-style pacing, but stdout IS
# the audio, so it can be piped into `stt stream` as an sttd session
# pipeline: pace ... | stt stream --adapter ...). Waits for --trigger
# before the first byte (deterministic client gating), feeds at --speed x
# real time, writes a small JSON report and exits at end of audio (stt
# stream then emits eof on stdin close).
cat >"$FIX/pace.py" <<'EOF'
#!/usr/bin/env python3
import argparse, json, os, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("--pcm", required=True)
ap.add_argument("--speed", type=float, default=1.0)
ap.add_argument("--chunk-ms", type=float, default=100.0)
ap.add_argument("--trigger", default=None)
ap.add_argument("--report", required=True)
ap.add_argument("--wait", type=float, default=30.0)
a = ap.parse_args()

if a.trigger:
    end = time.monotonic() + a.wait
    while not os.path.exists(a.trigger):
        if time.monotonic() > end:
            sys.stderr.write("pace: timeout waiting for %s\n" % a.trigger)
            sys.exit(1)
        time.sleep(0.02)
    os.unlink(a.trigger)  # consume: restarts must not re-feed

bps = 32000  # 16 kHz mono s16le
chunk = int(bps * a.chunk_ms / 1000.0)
data = open(a.pcm, "rb").read()
start = time.monotonic()
next_t = start
sent = 0
try:
    while sent < len(data):
        n = min(chunk, len(data) - sent)
        sys.stdout.buffer.write(data[sent:sent + n])
        sys.stdout.buffer.flush()
        sent += n
        next_t += (a.chunk_ms / 1000.0) / a.speed
        delay = next_t - time.monotonic()
        if delay > 0:
            time.sleep(delay)
except KeyboardInterrupt:
    sys.exit(130)
sys.stdout.buffer.close()
with open(a.report, "w") as f:
    json.dump({"audio_s": round(len(data) / bps, 2), "speed": a.speed,
               "wall_s": round(time.monotonic() - start, 2),
               "bytes": sent}, f)
EOF

# sttd_wrap.py — babysit one sttd: spawn it with stdout=PIPE and timestamp
# every mirror line with time.monotonic() as it is read (both raw and
# "<ms>\t<line>" forms), write sttd's pid to --pidfile, forward SIGTERM/
# SIGINT, kill it after --timeout. stderr is inherited (the harness
# redirects it to the per-server log).
cat >"$FIX/sttd_wrap.py" <<'EOF'
#!/usr/bin/env python3
import argparse, json, os, signal, subprocess, sys, threading, time

ap = argparse.ArgumentParser()
ap.add_argument("--pidfile", required=True)
ap.add_argument("--raw", required=True)
ap.add_argument("--stamped", required=True)
ap.add_argument("--timeout", type=float, default=400.0)
ap.add_argument("cmd", nargs=argparse.REMAINDER)
a = ap.parse_args()
if a.cmd and a.cmd[0] == "--":
    a.cmd = a.cmd[1:]
if not a.cmd:
    sys.exit("sttd_wrap: no command after --")

p = subprocess.Popen(a.cmd, stdout=subprocess.PIPE, stderr=None)
with open(a.pidfile, "w") as f:
    f.write(str(p.pid))

def forward(signum, _frame):
    try:
        p.send_signal(signal.SIGTERM)
    except ProcessLookupError:
        pass

signal.signal(signal.SIGTERM, forward)
signal.signal(signal.SIGINT, forward)

def watchdog():
    time.sleep(a.timeout)
    if p.poll() is None:
        p.kill()

threading.Thread(target=watchdog, daemon=True).start()

with open(a.raw, "w", buffering=1) as fr, open(a.stamped, "w", buffering=1) as fs:
    for raw in p.stdout:
        line = raw.decode("utf-8", "replace").rstrip("\n")
        fs.write("%.3f\t%s\n" % (time.monotonic() * 1000.0, line))
        fr.write(line + "\n")
        try:
            if json.loads(line).get("type") == "eof":
                break  # mirror saw eof: everything was published
        except ValueError:
            pass
try:
    p.wait(10)
except subprocess.TimeoutExpired:
    p.kill()
    p.wait(5)
rc = p.returncode or 0
sys.exit(rc if rc > 0 else 0)
EOF

# sample.py — N WS clients recording absolute time.monotonic() ms per
# message (S6.3 latency side A). Reuses ws_probe.WSClient verbatim: the
# probe is imported, not rewritten.
cat >"$FIX/sample.py" <<'EOF'
#!/usr/bin/env python3
import argparse, json, os, sys, threading, time

ap = argparse.ArgumentParser()
ap.add_argument("--url", required=True)
ap.add_argument("--token", required=True)
ap.add_argument("--clients", type=int, default=2)
ap.add_argument("--timeout", type=float, default=60.0)
ap.add_argument("--out", required=True)
ap.add_argument("--ws-probe", required=True)
a = ap.parse_args()
sys.path.insert(0, os.path.dirname(os.path.abspath(a.ws_probe)))
import ws_probe

results = [None] * a.clients

def worker(i):
    try:
        c = ws_probe.WSClient(a.url, token=a.token, timeout=a.timeout).connect()
        msgs, times = [], []
        close, reason = None, "timeout"
        deadline = time.monotonic() + a.timeout
        try:
            while time.monotonic() < deadline:
                kind, val = c.recv_message(deadline)
                now = time.monotonic() * 1000.0
                if kind == "text":
                    msgs.append(val)
                    times.append(round(now, 3))
                    if ws_probe.is_eof(val):
                        reason = "eof"
                        deadline = min(deadline, time.monotonic() + 5.0)
                elif kind == "close":
                    close, reason = val, "close"
                    break
        except Exception as e:  # bounded recv deadline: socket.timeout
            reason = "error: %s" % e
        finally:
            if reason != "close":
                close = c.close(deadline=time.monotonic() + 3.0)
            c.abort()
        results[i] = {"messages": msgs, "arrivals_ms": times,
                      "close": close, "reason": reason}
    except Exception as e:
        results[i] = {"error": str(e)}

threads = [threading.Thread(target=worker, args=(i,)) for i in range(a.clients)]
for t in threads:
    t.start()
for t in threads:
    t.join()

with open(a.out, "w") as f:
    json.dump({"clients": results}, f, indent=1)
errs = ["client %d: %s" % (i, r["error"]) for i, r in enumerate(results) if r.get("error")]
bad = ["client %d: close=%s msgs=%d" % (i, r.get("close"), len(r.get("messages", [])))
       for i, r in enumerate(results)
       if not r.get("error") and (r.get("close") != 1000 or not r.get("messages"))]
if errs or bad:
    print("sampler: FAIL %s %s" % ("; ".join(errs), "; ".join(bad)), file=sys.stderr)
    sys.exit(1)
print("sampler: ok (%d clients, %d/%d messages, close 1000)" %
      (a.clients, results[0]["messages"] and len(results[0]["messages"]),
       results[-1]["messages"] and len(results[-1]["messages"])))
EOF

# latency.py SAMPLER STAMPED OUT — S6.3 evidence: every client's events
# (everything after hello) must equal the mirror lines verbatim and in
# order; the WS-vs-mirror arrival delta must be p95 <= 20 ms over >= 20
# samples.
cat >"$FIX/latency.py" <<'EOF'
#!/usr/bin/env python3
import json, sys

def p95(vals):
    vals = sorted(vals)
    return vals[max(0, -(-len(vals) * 95 // 100) - 1)]

sampler_p, mirror_p, out_p = sys.argv[1:4]
mirror = []
for ln in open(mirror_p):
    ms, _, line = ln.rstrip("\n").partition("\t")
    mirror.append((float(ms), line))
mlines = [m[1] for m in mirror]
data = json.load(open(sampler_p))
problems, deltas, per_client = [], [], []
for i, c in enumerate(data["clients"]):
    if c.get("error"):
        problems.append("client %d: %s" % (i, c["error"]))
        continue
    msgs = c["messages"]
    if not msgs:
        problems.append("client %d: no messages" % i)
        continue
    try:
        first = json.loads(msgs[0])
    except ValueError:
        first = {}
    if first.get("type") != "hello":
        problems.append("client %d: first message is not hello" % i)
    events = msgs[1:]
    if events != mlines:
        problems.append("client %d: %d events != %d mirror lines (identical=%s)"
                        % (i, len(events), len(mlines), events == mlines))
        continue
    if c.get("close") != 1000:
        problems.append("client %d: close %s != 1000" % (i, c.get("close")))
    try:
        last = json.loads(msgs[-1])
    except ValueError:
        last = {}
    if last.get("type") != "eof":
        problems.append("client %d: eof is not the last message" % i)
    d = [round(t - mirror[j][0], 3) for j, t in enumerate(c["arrivals_ms"][1:])]
    deltas += d
    per_client.append({"close": c.get("close"), "events": len(events),
                       "p95_ms": p95(d) if d else None,
                       "max_ms": max(d) if d else None})
stats = {"mirror_events": len(mlines), "samples": len(deltas),
         "p95_ms": round(p95(deltas), 3) if deltas else None,
         "max_ms": max(deltas) if deltas else None,
         "min_ms": min(deltas) if deltas else None,
         "per_client": per_client}
json.dump({"stats": stats, "problems": problems}, open(out_p, "w"), indent=1)
print("latency: %s" % json.dumps(stats))
if len(mlines) < 20:
    problems.append("only %d events (< 20 latency samples)" % len(mlines))
if stats["p95_ms"] is None or stats["p95_ms"] > 20:
    problems.append("p95 %s ms exceeds the 20 ms contract bound" % stats["p95_ms"])
if problems:
    print("latency: FAIL %s" % "; ".join(problems), file=sys.stderr)
    sys.exit(1)
EOF

# Shared audio: beckett raw (S6.4 partials) and a 4x loop (S6.3 nucleus:
# ~40 s of paced audio -> ~30 events -> >= 20 latency samples).
sox "$BECKETT" -t raw "$T/beckett.raw" 2>/dev/null
[ -s "$T/beckett.raw" ] || fail "sox produced no raw PCM from $BECKETT"
cat "$T/beckett.raw" "$T/beckett.raw" "$T/beckett.raw" "$T/beckett.raw" >"$T/beckett-x4.raw"

# ============================================================================
section "S6.2 smoke: version, token, /healthz, lazy attach"

ver=$("$STTD" --version)
echo "$ver" | grep -Eq '^sttd [0-9]+\.[0-9]+\.[0-9]+ \(stt-remote/1\)$' \
	|| fail "sttd --version printed unexpected: $ver"
log "OK --version: $ver"

# --print-token + var/etc/stt-token: 64 hex, mode 0600, content matches.
tok=$("$STTD" --print-token)
printf '%s' "$tok" | grep -Eq '^[0-9a-f]{64}$' || fail "--print-token is not 64 hex: $tok"
[ -f var/etc/stt-token ] || fail "var/etc/stt-token was not created"
[ "$(stat -c '%a' var/etc/stt-token)" = "600" ] \
	|| fail "var/etc/stt-token mode is $(stat -c '%a' var/etc/stt-token), want 0600"
[ "$(cat var/etc/stt-token)" = "$tok" ] || fail "var/etc/stt-token != --print-token output"
log "OK --print-token: 64 hex, var/etc/stt-token mode 0600, content matches"

# Fresh file generation (first boot) also yields 64 hex @ 0600.
rm -f "$T/gen-token"
gtok=$("$STTD" --print-token --token-file "$T/gen-token")
printf '%s' "$gtok" | grep -Eq '^[0-9a-f]{64}$' || fail "generated token is not 64 hex"
[ "$(stat -c '%a' "$T/gen-token")" = "600" ] || fail "generated token mode != 0600"
log "OK token generation: fresh file 64 hex @ 0600"

start_server s1 --listen 127.0.0.1:0 --token "$TOK" --pipeline "python3 $FIX/idle.py"
hz=$(python3 -c 'import sys,urllib.request;print(urllib.request.urlopen(sys.argv[1],timeout=5).read().decode())' \
	"http://$CUR_ADDR/healthz") || fail "GET /healthz failed"
[ "$hz" = '{"status":"ok","protocol":"stt-remote/1","session":false}' ] \
	|| fail "/healthz idle body is: $hz"
log "OK /healthz idle: $hz"

timeout 15 python3 "$PROBE" collect "$CUR_URL" --token "$TOK" --expect 1 \
	--timeout 10 >"$T/s1.hello.json" 2>>"$LOG" \
	|| fail "lazy-attach collect failed; see $LOG"
jq -e '.messages[0] | fromjson | .type=="hello" and .protocol=="stt-remote/1" and .session==null' \
	"$T/s1.hello.json" >/dev/null \
	|| fail "first message is not hello with session:null: $(jq -c '.messages[0]' "$T/s1.hello.json")"
log "OK lazy attach: hello with \"session\":null"
stop_server

# ============================================================================
section "S6.3 events: fixture fan-out (2 clients + stdout mirror) and late client"

T1="$T/s2.t1"; T2="$T/s2.t2"
rm -f "$T1" "$T2"
SRV_MIRROR=1
start_server s2 --listen 127.0.0.1:0 --max-clients 8 --token "$TOK" \
	--pipeline "python3 $FIX/events10.py $T1 $T2"
SRV_MIRROR=0
n0=$(wc -l <"$CUR_ERR")

# 4 clients: mirror (1) + compare (2) + collect (1). compare proves the two
# concurrent clients identical; collect provides the full ordered message
# list + close code to diff against the mirror.
timeout 30 python3 "$PROBE" compare "$CUR_URL" "$CUR_URL" --token "$TOK" \
	--timeout 20 >"$T/s2.compare.json" 2>>"$LOG" &
CMP_PID=$!
ALL_PIDS="$ALL_PIDS $CMP_PID"
rm -f "$T/s2.collect.ready"
timeout 30 python3 "$PROBE" collect "$CUR_URL" --token "$TOK" --require-eof \
	--timeout 20 --ready-file "$T/s2.collect.ready" >"$T/s2.collect.json" 2>>"$LOG" &
COL_PID=$!
ALL_PIDS="$ALL_PIDS $COL_PID"
wait_grep_from "$CUR_ERR" "$((n0 + 1))" 'client connected \(total 4\)' 15 \
	's2 mirror+compare+collect connected'
touch "$T1" "$T2"
wait "$CMP_PID" || fail "ws_probe compare failed; see $LOG"
wait "$COL_PID" || fail "ws_probe collect failed; see $LOG"
rm -f "$T1" "$T2"   # before the supervisor restarts the fixture

jq -e '.identical == true and .count_a == 11 and .count_b == 11
       and .close_a == 1000 and .close_b == 1000' \
	"$T/s2.compare.json" >/dev/null \
	|| fail "compare report: $(cat "$T/s2.compare.json")"
jq -e '.close == 1000 and (.messages | length) == 11' "$T/s2.collect.json" >/dev/null \
	|| fail "collect did not see 11 messages and close 1000: $(cat "$T/s2.collect.json")"
jq -Rsc 'split("\n") | map(select(length > 0))' "$T/s2.mirror.ndjson" >"$T/s2.mirror.json"
jq -c '.messages[1:]' "$T/s2.collect.json" >"$T/s2.collect.events.json"
jq -e -n --slurpfile m "$T/s2.mirror.json" --slurpfile c "$T/s2.collect.events.json" \
	'($m[0] | length) == 10 and ($c[0] == $m[0])' >/dev/null \
	|| fail "WS events differ from the stdout mirror (want 10 verbatim lines)"
types=$(jq -r '.messages[1:] | map(fromjson.type) | join(",")' "$T/s2.collect.json")
[ "$types" = "start,partial,partial,partial,final,final,final,final,error,eof" ] \
	|| fail "unexpected event order: $types"
log "OK fixture fan-out: 10 events (start,3 partial,4 final,error,eof) identical on 2 clients + mirror, close 1000"

# Late client, second session of the same server: connect after `start`,
# before the rest. The fixture blocks on T2 until the client is in.
n1=$(wc -l <"$CUR_ERR")
rm -f "$T1" "$T2"
wait_grep_from "$CUR_ERR" "$((n1 + 1))" 'events10: waiting for' 15 \
	's2 fixture restarted and gated'
n2=$(wc -l <"$CUR_ERR")
touch "$T1"
wait_grep_from "$CUR_ERR" "$((n2 + 1))" 'session started \(id ' 10 's2 session 2 start'
rm -f "$T/s2.late.ready"
timeout 20 python3 "$PROBE" collect "$CUR_URL" --token "$TOK" --require-eof \
	--timeout 10 --ready-file "$T/s2.late.ready" >"$T/s2.late.json" 2>>"$LOG" &
LATE_PID=$!
ALL_PIDS="$ALL_PIDS $LATE_PID"
wait_file "$T/s2.late.ready" 10 'late client connected'
touch "$T2"
wait "$LATE_PID" || fail "late-client collect failed; see $LOG"
rm -f "$T1" "$T2"
jq -e '(.messages | length) == 11 and .close == 1000' "$T/s2.late.json" >/dev/null \
	|| fail "late client did not see 11 messages / close 1000"
jq -e '.messages[0] | fromjson | .type=="hello" and .session != null and .session.id != null' \
	"$T/s2.late.json" >/dev/null \
	|| fail "late client hello has no session object: $(jq -c '.messages[0]' "$T/s2.late.json")"
jq -c '.messages[1:]' "$T/s2.late.json" >"$T/s2.late.events.json"
jq -e -n --slurpfile m "$T/s2.mirror.json" --slurpfile l "$T/s2.late.events.json" \
	'($l[0][0] | fromjson | .type == "start") and ($l[0] == $m[0])' >/dev/null \
	|| fail "late client did not get the replayed start first (then the same 10 events)"
log "OK late client: hello with session object + replayed start, full session, close 1000"
stop_server

# ============================================================================
section "S6.3 real nucleus: paced beckett (echo adapter) via sttd, mirror vs WS"

T3="$T/s3.trigger"
rm -f "$T3"
SRV_MIRROR=1
start_server s3 --listen 127.0.0.1:0 --max-clients 8 --token "$TOK" \
	--pipeline "python3 $FIX/pace.py --trigger $T3 --pcm $T/beckett-x4.raw --speed 3 --report $T/s3.feed-report.json | $STT stream --adapter adapters/echo/stt-adapter-echo --vad=true --frame-ms=1000"
SRV_MIRROR=0
n0=$(wc -l <"$CUR_ERR")
timeout 60 python3 "$FIX/sample.py" --url "$CUR_URL" --token "$TOK" --clients 2 \
	--timeout 45 --out "$T/s3.sampler.json" --ws-probe "$PROBE" >>"$LOG" 2>>"$LOG" &
SAMP_PID=$!
ALL_PIDS="$ALL_PIDS $SAMP_PID"
wait_grep_from "$CUR_ERR" "$((n0 + 1))" 'client connected \(total 3\)' 15 \
	's3 sampler + mirror connected'
touch "$T3"
wait "$SAMP_PID" || fail "s3 sampler failed; see $LOG and $T/s3.sampler.json"
rm -f "$T3"
[ -s "$T/s3.feed-report.json" ] || fail "pace.py wrote no report"
python3 "$FIX/latency.py" "$T/s3.sampler.json" "$T/s3.mirror-stamped.ndjson" \
	"$T/s3.latency.json" >>"$LOG" 2>>"$LOG" \
	|| fail "s3 latency/equality check failed; see $T/s3.latency.json"
nfins=$(jq -Rs 'split("\n") | map(select(length > 0)) | map(fromjson | select(.type == "final")) | length' "$T/s3.mirror.ndjson")
p95=$(jq -r '.stats.p95_ms' "$T/s3.latency.json")
nsamp=$(jq -r '.stats.samples' "$T/s3.latency.json")
log "OK nucleus fan-out: $nfins finals on the mirror and both WS clients, p95 WS-vs-mirror ${p95} ms over ${nsamp} samples, close 1000"
stop_server

# ============================================================================
section "S6.3 partials over WS (sherpa zipformer)"

if [ -d "$SHERPA_MODEL" ]; then
	need "$SHERPA_AD"
	T4="$T/s4.trigger"
	rm -f "$T4"
	start_server s4 --listen 127.0.0.1:0 --token "$TOK" --partials \
		--pipeline "python3 $FIX/pace.py --trigger $T4 --pcm $T/beckett.raw --speed 3 --report $T/s4.feed-report.json | $STT stream --adapter adapters/sherpa/stt-adapter-sherpa --model var/models/sherpa-zipformer-en-kroko --vad=true --partials=true"
	n0=$(wc -l <"$CUR_ERR")
	timeout 240 python3 "$PROBE" collect "$CUR_URL" --token "$TOK" --require-eof \
		--timeout 200 --ready-file "$T/s4.ready" >"$T/s4.collect.json" 2>>"$LOG" &
	C4_PID=$!
	ALL_PIDS="$ALL_PIDS $C4_PID"
	wait_file "$T/s4.ready" 15 's4 client connected'
	touch "$T4"
	wait "$C4_PID" || fail "s4 sherpa collect failed; see $LOG"
	rm -f "$T4"
	npart=$(jq -r '[.messages[] | fromjson | select(.type=="partial")] | length' "$T/s4.collect.json")
	[ "$npart" -ge 1 ] || fail "no partial events over WS (sherpa partals not wired)"
	jq -e '.close == 1000' "$T/s4.collect.json" >/dev/null || fail "s4 close code != 1000"
	log "OK sherpa partials: $npart partial events over WS, close 1000"
	stop_server
else
	log "SKIP (models not cached): $SHERPA_MODEL"
fi

# ============================================================================
section "S6.4 security: default bind, 401, ?token=, max_clients, slow, churn"

# Default --listen: no flag at all -> 127.0.0.1:4719 (contract §9.1, D18).
start_server s5a --token "$TOK" --pipeline "python3 $FIX/idle.py"
case $CUR_ADDR in
127.0.0.1:4719) log "OK default bind: $CUR_ADDR (loopback only)" ;;
*) fail "default --listen bound $CUR_ADDR, want 127.0.0.1:4719" ;;
esac
stop_server

TOK2=fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210
T5="$T/s5.flood.trigger"
rm -f "$T5"
start_server s5b --listen 127.0.0.1:0 --max-clients 2 --token "$TOK" \
	--pipeline "python3 $FIX/flood.py $T5 600"

timeout 15 python3 "$PROBE" status "$CUR_URL" --no-token --expect-status 401 \
	>"$T/s5.401-none.json" 2>>"$LOG" || fail "no-token did not get 401"
timeout 15 python3 "$PROBE" status "$CUR_URL" --token "$TOK2" --expect-status 401 \
	>"$T/s5.401-wrong.json" 2>>"$LOG" || fail "wrong token did not get 401"
log "OK auth: no token -> 401, wrong token -> 401 (no upgrade)"

timeout 15 python3 "$PROBE" collect "$CUR_URL?token=$TOK" --expect 1 --timeout 10 \
	>"$T/s5.qs.json" 2>>"$LOG" || fail "?token= fallback did not upgrade"
jq -e '.messages[0] | fromjson | .type=="hello"' "$T/s5.qs.json" >/dev/null \
	|| fail "?token= hello missing"
log "OK auth: ?token= query fallback upgrades"

# max_clients 2: two holder clients (gated by --ready-file), then 503.
rm -f "$T/s5.h1.ready" "$T/s5.h2.ready"
timeout 20 python3 "$PROBE" collect "$CUR_URL" --token "$TOK" --timeout 6 \
	--ready-file "$T/s5.h1.ready" >"$T/s5.h1.json" 2>>"$LOG" &
H1=$!
ALL_PIDS="$ALL_PIDS $H1"
timeout 20 python3 "$PROBE" collect "$CUR_URL" --token "$TOK" --timeout 6 \
	--ready-file "$T/s5.h2.ready" >"$T/s5.h2.json" 2>>"$LOG" &
H2=$!
ALL_PIDS="$ALL_PIDS $H2"
wait_file "$T/s5.h1.ready" 10 'holder 1 connected'
wait_file "$T/s5.h2.ready" 10 'holder 2 connected'
timeout 15 python3 "$PROBE" status "$CUR_URL" --token "$TOK" --expect-status 503 \
	>"$T/s5.503.json" 2>>"$LOG" || fail "third client did not get 503 with --max-clients 2"
wait "$H1" || fail "holder 1 failed"
wait "$H2" || fail "holder 2 failed"
log "OK max_clients: --max-clients 2 -> third client HTTP 503"

# churn: 20 connect/read-hello/disconnect cycles, then 2 fresh simultaneous
# connections prove the slots were released; RSS of sttd before/after.
timeout 60 python3 "$PROBE" churn "$CUR_URL" --churn 20 --expect 2 --token "$TOK" \
	--pid "$CUR_PID" --timeout 10 >"$T/s5.churn.json" 2>>"$LOG" \
	|| fail "churn failed; see $T/s5.churn.json"
jq -e '.fresh_ok == 2 and .cycles == 20' "$T/s5.churn.json" >/dev/null \
	|| fail "slots not released after churn: $(cat "$T/s5.churn.json")"
rssb=$(jq -r '.rss_before_kb' "$T/s5.churn.json")
rssa=$(jq -r '.rss_after_kb' "$T/s5.churn.json")
log "OK churn: 20 cycles, 2/2 fresh clients after, sttd RSS ${rssb} kB -> ${rssa} kB"

# slow client: tiny SO_RCVBUF, reads hello then stops. The flood (600 x
# ~31 KB) jams its window, the 256-deep queue overflows -> 1013 drop,
# while the healthy client receives the whole stream and closes 1000.
n0=$(wc -l <"$CUR_ERR")
rm -f "$T/s5.healthy.ready"
timeout 90 python3 "$PROBE" collect "$CUR_URL" --token "$TOK" --require-eof \
	--timeout 60 --ready-file "$T/s5.healthy.ready" >"$T/s5.healthy.json" 2>>"$LOG" &
HP=$!
ALL_PIDS="$ALL_PIDS $HP"
timeout 90 python3 "$PROBE" slow "$CUR_URL" --token "$TOK" --timeout 30 \
	>"$T/s5.slow.json" 2>>"$LOG" &
SP=$!
ALL_PIDS="$ALL_PIDS $SP"
wait_file "$T/s5.healthy.ready" 10 'healthy client connected'
wait_grep_from "$CUR_ERR" "$((n0 + 1))" 'client connected \(total 2\)' 10 \
	's5 slow+healthy connected'
touch "$T5"
wait "$SP" || fail "slow probe failed; see $T/s5.slow.json"
wait "$HP" || fail "healthy collect failed; see $T/s5.healthy.json"
rm -f "$T5"
jq -e '(.close == 1013 or .abrupt == true) and .saw_eof == false' \
	"$T/s5.slow.json" >/dev/null \
	|| fail "slow client was not dropped with 1013 before eof: $(cat "$T/s5.slow.json")"
jq -e '.close == 1000 and (.messages | length) == 603' "$T/s5.healthy.json" >/dev/null \
	|| fail "healthy client did not receive the whole stream (want 603 msgs, close 1000)"
sclose=$(jq -r '.close // "abrupt"' "$T/s5.slow.json")
log "OK slow client: dropped with $sclose (1013) after $(jq -r '.survived_ms' "$T/s5.slow.json") ms; healthy client got all 603 messages, close 1000"
stop_server

# ============================================================================
section "Stage 6 summary"

s2c=$(jq -c '{identical, close_a, close_b, msgs: .count_a}' "$T/s2.compare.json")
s3s=$(jq -c '.stats | {events: .mirror_events, samples, p95_ms, max_ms}' "$T/s3.latency.json")
if [ -d "$SHERPA_MODEL" ]; then
	s4n=$(jq -r '[.messages[] | fromjson | select(.type=="partial")] | length' "$T/s4.collect.json")
	s4line="sherpa partials over WS : $s4n partials, close 1000"
else
	s4line="sherpa partials over WS : SKIP (models not cached)"
fi
log "evidence:"
log "  S6.2 --version / token  : $ver"
log "  S6.2 /healthz idle      : $hz"
log "  S6.2 lazy attach        : hello session:null"
log "  S6.3 fixture fan-out    : 10 events on 2 clients + mirror (identical), $s2c"
log "  S6.3 late client        : hello(session)+replayed start, 11 msgs, close 1000"
log "  S6.3 echo nucleus       : $s3s (close 1000 on both WS clients)"
log "  S6.3 partials           : $s4line"
log "  S6.4 auth               : 401 (no token), 401 (wrong token), ?token= ok"
log "  S6.4 default bind       : 127.0.0.1:4719 (loopback only)"
log "  S6.4 max_clients        : 2 holders -> 3rd client HTTP 503"
log "  S6.4 slow client        : $sclose (1013) while healthy got 603 msgs close 1000"
log "  S6.4 churn (20 cycles)  : 2/2 fresh clients after, RSS ${rssb} kB -> ${rssa} kB"
log ""
log "ALL STAGE 6 CHECKS OK"
