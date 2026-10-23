#!/usr/bin/env python3
"""Per-repeat word coverage for the Stage 3 stream assets.

The Stage 3 stream repeats the 9.963 s Beckett clip with a deterministic gap
cycle. This metric scores each repeat independently: finals intersecting the
repeat's time window are concatenated and matched in order against the
reference words, allowing Levenshtein <= 1 for words up to 4 letters and <= 2
for longer words (the tiny model's normal fair/fail variance). It measures
real losses (dropped words/phrases), not spelling.

Usage:
  python3 tests/coverage.py REPORT.json [--repeats N] [--speech-s S]
      [--gaps 0.3,0.6,...] [--threshold PCT] [--ref "text"] [--single] [--json]

`--ref` overrides the English Beckett reference (needed for the Spanish S5.4
clip). `--single` scores all finals of the report once, without the Stage 3
repeat windows (use it for a one-shot ES/EN recording).

Exit code 1 when the mean coverage is below --threshold (default 0).
"""
import argparse
import json
import re
import sys
import unicodedata

REF = "ever tried ever failed no matter try again fail again fail better".split()


def words(text):
    # NFD + drop combining marks keeps accented Spanish words (país -> pais)
    # comparable to the model output, while the ASCII filter keeps numerals
    # and apostrophes and drops punctuation.
    text = unicodedata.normalize("NFD", text.lower())
    text = "".join(c for c in text if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9' ]", " ", text).split()


def levenshtein(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1,
                           prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def tolerance(word):
    return 1 if len(word) <= 4 else 2


def score(got, ref):
    # Word-level LCS with fuzzy matches. Unlike a greedy forward scan, one
    # substitution early in the phrase cannot make the matcher skip ahead and
    # lose the rest of the clause (observed on the Spanish S5.4 clip:
    # "qué" -> "si" cascaded to 41 % under the old greedy matcher).
    prev = [0] * (len(got) + 1)
    for want in ref:
        cur = [0] * (len(got) + 1)
        tol = tolerance(want)
        for j, word in enumerate(got, 1):
            best = max(prev[j], cur[j - 1])
            if levenshtein(word, want) <= tol:
                best = max(best, prev[j - 1] + 1)
            cur[j] = best
        prev = cur
    return prev[-1] / len(ref)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("report")
    ap.add_argument("--repeats", type=int, default=30)
    ap.add_argument("--speech-s", type=float, default=9.963375)
    ap.add_argument("--gaps", default="0.3,0.6,0.9,1.2,0.5")
    ap.add_argument("--threshold", type=float, default=0.0)
    ap.add_argument("--ref", default=" ".join(REF),
                    help="reference transcript (default: English Beckett phrase)")
    ap.add_argument("--single", action="store_true",
                    help="score all finals once (no repeat windows)")
    ap.add_argument("--ndjson", action="store_true",
                    help="report is a stt-events/1 NDJSON file (e.g. stt once)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    threshold = args.threshold / 100.0 if args.threshold > 1 else args.threshold

    gaps = [float(g) for g in args.gaps.split(",") if g.strip()]
    periods = [args.speech_s + g for g in gaps]
    starts = [0.0]
    for r in range(args.repeats):
        starts.append(starts[-1] + periods[r % len(periods)])

    if args.ndjson:
        finals = []
        with open(args.report, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if ev.get("type") == "final":
                    finals.append(ev)
    else:
        data = json.load(open(args.report))
        finals = data["finals"]
    ref = words(args.ref)
    if args.single:
        got = []
        for f in finals:
            got += words(f.get("text", ""))
        scores = [score(got, ref)]
    else:
        scores = []
        for r in range(args.repeats):
            # Include finals crossing either edge: a segment may span the gap.
            lo = starts[r] - 0.3
            hi = starts[r] + periods[r % len(periods)] + 0.3
            got = []
            for f in finals:
                t0, t1 = f.get("t0") or 0, f.get("t1") or 0
                if t0 < hi and t1 > lo:
                    got += words(f.get("text", ""))
            scores.append(score(got, ref))

    scores.sort()
    mean = sum(scores) / len(scores)
    out = {
        "mean": round(mean, 4),
        "median": round(scores[len(scores) // 2], 4),
        "min": round(scores[0], 4),
        "max": round(scores[-1], 4),
        "repeats": 1 if args.single else args.repeats,
        "transcribed_words": sum(len(words(f.get("text", ""))) for f in finals),
    }
    if args.json:
        print(json.dumps(out))
    else:
        print(f"coverage mean={out['mean']:.1%} median={out['median']:.1%} "
              f"min={out['min']:.1%} max={out['max']:.1%} "
              f"({out['repeats']} repeats, {out['transcribed_words']} transcribed words)")
    return 0 if mean >= threshold else 1


if __name__ == "__main__":
    sys.exit(main())
