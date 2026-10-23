#!/bin/sh
# Stage 5 checks — S5.3–S5.9 (sherpa-onnx engine + remote fan-out).
#
# Requires: var/bin/stt, adapters (make), the model cache in var/models
# (scripts/fetch-model.sh), jq, sox, python3, curl (only for model fetch).
# The script is self-contained and takes ~2-3 min with a warm model cache
# (each sherpa process loads its model; ES float is the slowest).
#
# Checks:
#   S5.3  sherpa handshake, EN/ES transcription, partials
#   S5.4  fuzzy ES/EN coverage >= 80 % vs reference transcripts
#   S5.5  RTF <= 0.35 and adapter RSS < 300 MB with fixed 5 s frames
#   S5.6  model cache idempotent (--offline)
#   S5.7  engine selection: config default = moonshine; [adapter] selects sherpa
#   S5.8  --out tcp:// and unix:// fan-out: 2 clients, identical events,
#         disconnect isolation, p95 overhead <= 10 ms
#   S5.9  partials end-to-end + stt-captions interim rendering
#
# Set STT_REGRESS=1 to also run the stage 1/2/3/4 scripts at the end.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
STT="$ROOT/var/bin/stt"
ADAPTER="$ROOT/adapters/sherpa/stt-adapter-sherpa"
EN="$ROOT/var/models/sherpa-zipformer-en-kroko"
ES="$ROOT/var/models/sherpa-zipformer-es"
BECKETT="$ROOT/tests/assets/beckett.wav"
TMP="$ROOT/var/tmp/stage5"
mkdir -p "$TMP"

EN_REF="ever tried ever failed no matter try again fail again fail better"
ES_REF="No preguntes qué puede hacer tu país por ti, pregunta qué puedes hacer tú por tu país"

fail() { echo "FAIL: $*" >&2; exit 1; }
need() { [ -e "$1" ] || fail "missing $1 (run: make / make models)"; }

need "$STT"; need "$ADAPTER"; need "$BECKETT"
[ -d "$EN" ] || fail "missing $EN (run: scripts/fetch-model.sh --model kroko-en)"
[ -d "$ES" ] || fail "missing $ES (run: scripts/fetch-model.sh --model kroko-es)"
[ -f "$ES/test_wav0.wav" ] || fail "missing $ES/test_wav0.wav (run: scripts/fetch-model.sh --model kroko-es)"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v sox >/dev/null 2>&1 || fail "sox not found"

# S5.6: cache idempotence before doing any inference (fast, no network).
echo "== S5.6: model cache is idempotent with --offline =="
for m in kroko-en kroko-es; do
	out=$(sh scripts/fetch-model.sh --model "$m" --offline)
	printf '%s\n' "$out" | grep -q '^cached:' || fail "fetch-model --model $m --offline did not hit the cache"
	printf '%s\n' "$out" | grep -q '^model ready:' || fail "fetch-model --model $m did not finish"
	echo "OK $m: $(printf '%s\n' "$out" | grep -c '^cached:') cached files"
done

# Shared assets: EN beckett raw, ES bundled clip resampled to the 16 kHz contract.
sox "$BECKETT" -t raw "$TMP/beckett.raw" 2>/dev/null
sox "$ES/test_wav0.wav" -r 16000 -c 1 -b 16 "$TMP/es16k.wav" 2>/dev/null \
	|| fail "sox could not resample $ES/test_wav0.wav"

echo
echo "== S5.3/S5.4: sherpa EN with partials (coverage >= 80%) =="
timeout 240 "$STT" once --adapter "$ADAPTER" --model "$EN" --frame-ms 5000 \
	--partials "$BECKETT" >"$TMP/s54-en.ndjson" 2>"$TMP/s54-en.err" \
	|| fail "stt once (EN) failed; see $TMP/s54-en.err"
npartial=$(jq -s '[.[] | select(.type=="partial")] | length' "$TMP/s54-en.ndjson")
[ "$npartial" -gt 0 ] || fail "no partial events (sherpa capability not wired)"
if jq -s -e 'any(.[]; .type=="final" and ((.text // "") | test("fail better"; "i")))' \
	"$TMP/s54-en.ndjson" >/dev/null; then :; else
	fail "EN final does not contain 'fail better'"
fi
en_cov=$(python3 tests/coverage.py "$TMP/s54-en.ndjson" --ndjson --single \
	--ref "$EN_REF" --threshold 80) || fail "EN coverage below 80%"
echo "OK EN: $en_cov; partials: $npartial"

echo
echo "== S5.3/S5.4: sherpa ES on the model's bundled clip (coverage >= 80%) =="
timeout 300 "$STT" once --adapter "$ADAPTER" --model "$ES" --frame-ms 5000 \
	"$TMP/es16k.wav" >"$TMP/s54-es.ndjson" 2>"$TMP/s54-es.err" \
	|| fail "stt once (ES) failed; see $TMP/s54-es.err"
es_cov=$(python3 tests/coverage.py "$TMP/s54-es.ndjson" --ndjson --single \
	--ref "$ES_REF" --threshold 80) || fail "ES coverage below 80%"
echo "OK ES: $es_cov"

echo
echo "== S5.5: RTF <= 0.35 and RSS < 300 MB with fixed 5 s frames =="
for lang in en es; do
	if [ "$lang" = en ]; then
		wav="$BECKETT"; model="$EN"
	else
		wav="$TMP/es16k.wav"; model="$ES"
	fi
	timeout 300 "$STT" once --adapter "$ADAPTER" --model "$model" \
		--vad=false --frame-ms 5000 "$wav" >"$TMP/s55-$lang.ndjson" 2>"$TMP/s55-$lang.err" \
		|| fail "stt once --vad=false ($lang) failed; see $TMP/s55-$lang.err"
	maxrtf=$(jq -s '[.[] | select(.type=="final") | .rtf] | max' "$TMP/s55-$lang.ndjson")
	rss=$(jq -r 'select(.type=="eof") | .rss_kb' "$TMP/s55-$lang.ndjson")
	awk -v r="$maxrtf" 'BEGIN{exit !(r<=0.35)}' || fail "$lang RTF $maxrtf > 0.35"
	[ "$rss" -gt 0 ] && [ "$rss" -lt 300000 ] || fail "$lang RSS ${rss} kB out of range"
	echo "OK $lang: max RTF $maxrtf, RSS ${rss} kB"
done

echo
echo "== S5.7: engine selection (config default moonshine; [adapter] selects sherpa) =="
timeout 120 "$STT" once "$BECKETT" >"$TMP/s57-default.ndjson" 2>"$TMP/s57-default.err" \
	|| fail "default-engine stt once failed; see $TMP/s57-default.err"
jq -s -e 'any(.[]; .type=="final" and (.model == "moonshine-tiny"))' \
	"$TMP/s57-default.ndjson" >/dev/null \
	|| fail "config/stt.toml no longer defaults to moonshine-tiny"
jq -s -e 'any(.[]; .type=="final" and ((.text // "") | test("ever tried"; "i")))' \
	"$TMP/s57-default.ndjson" >/dev/null || fail "default engine text regression"
echo "OK default engine: moonshine-tiny"

CFG="$TMP/s57-sherpa.toml"
cat >"$CFG" <<EOF
[adapter]
cmd = "adapters/sherpa/stt-adapter-sherpa"
args = ["--model", "var/models/sherpa-zipformer-en-kroko", "--threads", "4"]

[output]
partials = true
listen = ""
EOF
timeout 240 "$STT" once --config "$CFG" --frame-ms 5000 "$BECKETT" \
	>"$TMP/s57-config.ndjson" 2>"$TMP/s57-config.err" \
	|| fail "config-selected sherpa failed; see $TMP/s57-config.err"
jq -s -e 'any(.[]; .type=="final" and (.model == "sherpa-zipformer-en-kroko"))' \
	"$TMP/s57-config.ndjson" >/dev/null || fail "[adapter] did not select sherpa"
jq -s -e 'any(.[]; .type=="partial")' "$TMP/s57-config.ndjson" >/dev/null \
	|| fail "[output] partials = true did not take effect"
echo "OK [adapter]/[output] config selection: sherpa + partials"

echo
echo "== S5.8: --out fan-out (tcp + unix): 2 clients, isolation, p95 <= 10 ms =="
for kind in tcp unix; do
	port=$([ "$kind" = tcp ] && echo "${STT_FANOUT_PORT:-4799}" || echo "")
	if [ "$kind" = tcp ]; then
		addr="tcp://127.0.0.1:$port"
	else
		addr="unix://$TMP/stt-fanout.sock"
		rm -f "$TMP/stt-fanout.sock"
	fi
	timeout 240 python3 tests/fanout_probe.py --stt "$STT" --adapter "$ADAPTER" \
		--model "$EN" --pcm "$TMP/beckett.raw" --speed 2 --addr "$addr" \
		--clients 2 --late-after 1.0 --report "$TMP/fanout-$kind.json" \
		>"$TMP/fanout-$kind.summary" 2>"$TMP/fanout-$kind.err" \
		|| fail "fanout probe ($kind) failed; see $TMP/fanout-$kind.err"
	jq -e '.summary | .exit_code == 0 and (.errors | length) == 0 and
		.identical == true and .disconnected_ok == true and .late_client == true and
		.client_events[1] >= 2 and .overhead_p95_s <= 0.010 and
		.overhead_max_s <= 0.050' "$TMP/fanout-$kind.json" >/dev/null \
		|| fail "fanout ($kind) thresholds not met: $(cat "$TMP/fanout-$kind.summary")"
	cat "$TMP/fanout-$kind.summary"
	echo "OK $kind: identical events on 2 clients, disconnect isolated"
done

echo
echo "== S5.9: partials during speech + stt-captions interim rendering =="
python3 - "$TMP/beckett.raw" "$TMP/s59-long.raw" <<'EOF'
import sys
speech = open(sys.argv[1], "rb").read()
gap = b"\x00" * int(32000 * 0.5)
open(sys.argv[2], "wb").write((speech + gap) * 3)  # ~31 s of audio
EOF
timeout 300 python3 tests/feed_stream.py --stt "$STT" --adapter "$ADAPTER" \
	--model "$EN" --pcm "$TMP/s59-long.raw" --speed 1 --frame-ms 5000 \
	--min-segment-ms 3000 --partials --report "$TMP/s59-report.json" \
	>"$TMP/s59-summary.json" 2>"$TMP/s59.err" || fail "partials feed failed; see $TMP/s59.err"
wall=$(jq -r '.wall_s' "$TMP/s59-summary.json")
first_partial=$(jq -r '[.events[] | select(.event.type=="partial") | .arrival] | min' "$TMP/s59-report.json")
npartial=$(jq -r '[.events[] | select(.event.type=="partial")] | length' "$TMP/s59-report.json")
[ "$npartial" -gt 0 ] || fail "no partials in the sherpa stream"
awk -v p="$first_partial" -v w="$wall" 'BEGIN{exit !(p <= w - 1.0)}' \
	|| fail "first partial arrived after the feed ended (${first_partial}s vs ${wall}s)"
jq -e '
	[.events[] | select(.event.type=="final") |
	 {f:(.event.frame // -1), a:.arrival, t:((.event.text // "")|ascii_downcase)}] as $fs
	| [.events[] | select(.event.type=="partial") |
	   {f:(.event.frame // -1), a:.arrival, t:((.event.text // "")|ascii_downcase)} |
	   select(.t != "")] as $ps
	| (($ps | length) > 0) and
	  ($ps | all(. as $p | any($fs[];
	    (.f == $p.f) and (.a >= $p.a) and (.t | contains($p.t)))))
' "$TMP/s59-report.json" >/dev/null \
	|| fail "a partial was not confirmed by a later final of the same frame"
# `stt once` output has partials from the same real run; render it as captions.
sh scripts/stt-captions.sh --render-only <"$TMP/s54-en.ndjson" >"$TMP/s59-captions.txt"
grep -q '… ever tried' "$TMP/s59-captions.txt" || fail "captions did not render interim text"
grep -q 'ever tried' "$TMP/s59-captions.txt" || fail "captions did not render the final text"
echo "OK partials: $npartial interim events; first at ${first_partial}s (feed ${wall}s)"
echo "OK captions: interim + final rendered ($TMP/s59-captions.txt)"

if [ "${STT_REGRESS:-0}" = "1" ]; then
	echo
	echo "== regressions: stage 1..4 =="
	sh tests/run-stage1-tests.sh
	sh tests/run-stage2-tests.sh
	sh tests/run-stage3-tests.sh
	sh tests/run-stage4-tests.sh
fi

echo
echo "Stage 5 checks: ALL OK"
