#!/usr/bin/env python3
"""stt-correct — keyboard-style post-process corrector prototype (Laya judge).

Implements the design in docs/MODELOS.md §6.2 (canal ruidoso / teclado):
  1. suspicion signal: confusion sets of the target language (+ optional
     disagreement between two engines via --alt transcript),
  2. closed candidate space: only the confusion-set forms (or the two engine
     hypotheses) — never generated text,
  3. decision: Laya typed question (`choice`) with a DESCRIPTION PER CANDIDATE
     (mandatory: measured 2026-10-25, without descriptions the judge picks the
     wrong form), accepted only over calibrated-probability gates,
  4. edit budget: at most --max-changes per sentence; everything else stays.

STATUS (2026-10-25, session 020/021): the plumbing works but the zero-shot
judge is NOT validated for Spanish function-word/accent confusion sets —
measured precision 9-18% at every gate (docs/MODELOS.md §6.4). It runs as a
DRY RUN by default (decisions only); pass --rewrite to apply gated edits.

VALIDATED MODE (session 021, MODELOS §6.4.1): lexical-neighbour candidates
(--candidates, every candidate with a semantic description) + left context
(--context 1) + per-slot requests (--per-slot) + strict gate (--gate-p 0.7):
measured 100% precision / 75% recall on tests/corrector_eval.py class ctx-*.
Keep --sources confusion-set OFF until a fine-tuned judge exists.

The judge is a TypeSafe `/v1/systemone` server:
  var/tmp/ggmlc/build/examples/laya/laya serve \
      var/models/laya-multilingual/laya_multilingual_q8_0.gguf --port 8092

Post-process only (MODELOS §6.3): never in the hot path.

Usage:
  stt-correct.py --text "No preguntes si puede hacer tu pais"
  stt-correct.py sentences.txt
  stt-correct.py --ndjson finals.ndjson --decisions dec.ndjson
"""
import argparse, difflib, json, re, sys, time, urllib.request

# ---------------------------------------------------------------- confusion sets
# Members are mutually confusable ASR spellings; every member is a candidate
# whenever any member appears. Keep sets closed and small (teclado pattern).
SETS_ES = [
    {"que", "qué"}, {"si", "sí"}, {"tu", "tú"}, {"se", "sé"}, {"mi", "mí"},
    {"mas", "más"}, {"como", "cómo"}, {"cuando", "cuándo"}, {"quien", "quién"},
    {"donde", "dónde"}, {"cual", "cuál"}, {"cuanto", "cuánto"},
    {"esta", "está"}, {"hay", "ay"}, {"el", "él"}, {"aun", "aún"},
    {"por", "para"}, {"seria", "sería"}, {"de", "dé"},
]
SETS_EN = [
    {"to", "too", "two"}, {"their", "there", "they're"}, {"its", "it's"},
    {"your", "you're"}, {"fail", "fell", "feel", "fill"},
]

# Descriptions are part of the prompt (criteria), not decoration.
DESCR_ES = {
    "que": "conjunción o pronombre relativo, sin tilde",
    "qué": "interrogativo o exclamativo, con tilde",
    "si": "condicional, sin tilde",
    "sí": "afirmación, con tilde",
    "tu": "posesivo, sin tilde",
    "tú": "pronombre personal, con tilde",
    "se": "pronombre reflexivo o impersonal, sin tilde",
    "sé": "verbo saber (yo sé) o imperativo de ser, con tilde",
    "mi": "posesivo, sin tilde",
    "mí": "pronombre personal con preposición, con tilde",
    "mas": "conjunción adversativa (pero), sin tilde",
    "más": "cantidad o comparación, con tilde",
    "como": "conjunción comparativa o verbo comer, sin tilde",
    "cómo": "interrogativo o exclamativo, con tilde",
    "cuando": "conjunción temporal, sin tilde",
    "cuándo": "interrogativo, con tilde",
    "quien": "pronombre relativo, sin tilde",
    "quién": "interrogativo, con tilde",
    "donde": "adverbio de lugar relativo, sin tilde",
    "dónde": "interrogativo, con tilde",
    "cual": "pronombre relativo, sin tilde",
    "cuál": "interrogativo, con tilde",
    "cuanto": "indefinido o relativo, sin tilde",
    "cuánto": "interrogativo o exclamativo, con tilde",
    "esta": "verbo estar (él/ella) o demostrativo, sin tilde",
    "está": "verbo estar, tercera persona, con tilde",
    "hay": "verbo haber impersonal (existir)",
    "ay": "interjección de dolor o sorpresa",
    "el": "artículo masculino",
    "él": "pronombre personal, con tilde",
    "aun": "incluso, sin tilde",
    "aún": "todavía, con tilde",
    "por": "preposición de causa, medio o movimiento",
    "para": "preposición de destino, fin o propósito",
    "seria": "adjetivo (grave), sin tilde",
    "sería": "condicional del verbo ser, con tilde",
    "de": "preposición",
    "dé": "verbo dar, subjuntivo, con tilde",
}
DESCR_EN = {
    "to": "preposición / infinitive marker",
    "too": "adverbio (also / excessively)",
    "two": "el número 2",
    "their": "posesivo de ellos",
    "there": "lugar (over there) o existencial (there is)",
    "they're": "contracción de they are",
    "its": "posesivo de it",
    "it's": "contracción de it is / it has",
    "your": "posesivo tuyo",
    "you're": "contracción de you are",
    "fail": "no tener éxito (verbo)",
    "fell": "pasado del verbo to fall (caer)",
    "feel": "sentir / percibir",
    "fill": "llenar",
}

TOKEN_RE = re.compile(r"[^\W_]+(?:'[^\W_]+)?", re.UNICODE)


def confusables(word, sets):
    wl = word.lower()
    for s in sets:
        if wl in s:
            return s
    return None


def tokenize(text):
    return [(m.start(), m.end(), m.group(0)) for m in TOKEN_RE.finditer(text)]


def suspicious_slots(text, lang="es", alt_text=None, extra_groups=None):
    """Slots with a closed candidate space (V4: confusion sets + engine
    disagreement + caller-supplied lexical neighbour groups). Each slot:
    {start, end, word, candidates, descs, reason}. A candidate MUST carry a
    semantic description: the judge scores criteria *descriptions* against the
    state (measured 2026-10-25), bare-word descriptions degrade it badly
    (playa/plaza: 0.51 with descriptions vs 0.07 bare)."""
    sets = list(SETS_ES if lang == "es" else SETS_EN)
    slots = []
    extra_words = {}
    for g in (extra_groups or []):
        for w in g:
            extra_words.setdefault(w.lower(), g)
    for start, end, word in tokenize(text):
        wl = word.lower()
        g = extra_words.get(wl)
        if g:
            slots.append({"start": start, "end": end, "word": word,
                          "candidates": sorted(g), "descs": dict(g),
                          "reason": "lexical-neighbour"})
            continue
        s = confusables(word, sets)
        if s:
            slots.append({"start": start, "end": end, "word": word,
                          "candidates": sorted(s), "descs": {},
                          "reason": "confusion-set"})
    if alt_text:
        mine = [w for _, _, w in tokenize(text)]
        theirs = [w for _, _, w in tokenize(alt_text)]
        sm = difflib.SequenceMatcher(a=mine, b=theirs, autojunk=False)
        tok = tokenize(text)
        idx = 0
        for tag, i1, i2, j1, j2 in sm.get_opcodes():
            if tag in ("replace", "delete"):
                for k in range(i1, i2):
                    start, end, word = tok[k]
                    cand = {word.lower()}
                    if tag == "replace":
                        for w in theirs[j1:j2]:
                            cand.add(w.lower())
                    s = confusables(word, sets)
                    if s:
                        cand |= s
                    if len(cand) > 1 and not any(
                            sl["start"] == start for sl in slots):
                        slots.append({"start": start, "end": end, "word": word,
                                      "candidates": sorted(cand), "descs": {},
                                      "reason": "engine-disagreement"})
    slots.sort(key=lambda sl: sl["start"])
    return slots


# ---------------------------------------------------------------- judge
def _post(url, body, timeout=120):
    req = urllib.request.Request(
        url + "/v1/systemone", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        out = json.load(r)
    return out, (time.monotonic() - t0) * 1000.0


def _question(slot, lang, idx, flavor="es"):
    descs = dict(DESCR_ES if lang == "es" else DESCR_EN)
    descs.update(slot.get("descs") or {})
    crit = {}
    for c in slot["candidates"]:
        crit[c] = descs.get(c, c)
    if flavor == "en":
        instr = "Which word belongs in the {%d} slot?" % idx
    else:
        instr = "¿Qué palabra va en el hueco {%d}?" % idx
    return {"type": "choice", "instructions": instr, "criteria": crit}


def _state(text, slots, lang, context=""):
    """Sentence with every slot marked; markers are inserted back to front.
    `context` = previous sentence(s): measured 2026-10-25 (Sesión 021) that the
    judge needs it to pick among lexical neighbours (playa/plaza 0.03 -> 0.53,
    médico/jurado 0.07 -> 0.57 with left context)."""
    out = text
    for i, sl in sorted(enumerate(slots), key=lambda kv: -kv[1]["start"]):
        out = out[:sl["start"]] + "{%d}" % (i + 1) + out[sl["end"]:]
    lead = ("Transcripción de voz a texto; la palabra de cada hueco viene del "
            "reconocedor y puede contener un error. Frase: " if lang == "es"
            else "Speech-to-text transcript; each braced word comes from the "
                 "recognizer and may contain an error. Sentence: ")
    pre = ""
    if context:
        pre = ("Contexto previo: «%s». " if lang == "es"
               else "Previous context: «%s». ") % context
    return pre + lead + "«" + out + "»"


def collect(text, judge, lang="es", batch=True, flavor="es", context="",
            extra_groups=None, alt_text=None, sources=None):
    """Judge every suspicious slot; returns slots with per-candidate probs."""
    slots = suspicious_slots(text, lang, alt_text=alt_text,
                             extra_groups=extra_groups)
    if sources:
        slots = [sl for sl in slots if sl["reason"] in sources]
    if not slots:
        return [], 0.0
    if batch:
        state = _state(text, slots, lang, context)
        questions = {"w%d" % (i + 1): _question(sl, lang, i + 1, flavor)
                     for i, sl in enumerate(slots)}
        out, ms = _post(judge, {"state": state, "questions": questions})
        for i, sl in enumerate(slots):
            ans = out["answers"]["w%d" % (i + 1)]
            sl["probs"] = ans["probabilities"]
            sl["judge_ms"] = ms
    else:
        ms = 0.0
        for i, sl in enumerate(slots):
            state = _state(text, [sl], lang, context)
            out, ms1 = _post(judge, {
                "state": state,
                "questions": {"w": _question(sl, lang, 1, flavor)}})
            sl["probs"] = out["answers"]["w"]["probabilities"]
            sl["judge_ms"] = ms1
            ms += ms1
    for sl in slots:
        ranked = sorted(sl["probs"].items(), key=lambda kv: -kv[1])
        sl["best"], sl["best_p"] = ranked[0]
        sl["margin"] = ranked[0][1] - ranked[1][1] if len(ranked) > 1 else 1.0
    return slots, ms


def apply_gates(slots, gate_p, gate_margin, max_changes):
    """Accept only gated edits, best margin first, within the edit budget."""
    for sl in slots:
        sl["edit"] = (sl["best"].lower() != sl["word"].lower())
        sl["accepted"] = False
        sl["why"] = "keep-original" if not sl["edit"] else "below-gate"
    edits = [sl for sl in slots if sl["edit"]]
    for sl in sorted(edits, key=lambda s: -s["margin"])[:max_changes]:
        if sl["best_p"] >= gate_p and sl["margin"] >= gate_margin:
            sl["accepted"] = True
            sl["why"] = "gate-ok"
        else:
            sl["why"] = "below-gate (p=%.2f margin=%.2f)" % (sl["best_p"],
                                                             sl["margin"])
    for sl in sorted(edits, key=lambda s: -s["margin"])[max_changes:]:
        sl["why"] = "over-edit-budget"
    return slots


def rewrite(text, slots):
    out = text
    for sl in sorted([s for s in slots if s["accepted"]],
                     key=lambda s: -s["start"]):
        new = sl["best"]
        if sl["word"][:1].isupper():
            new = new[:1].upper() + new[1:]
        out = out[:sl["start"]] + new + out[sl["end"]:]
    return out


def correct(text, judge, lang="es", gate_p=0.5, gate_margin=0.2,
            max_changes=3, batch=True, flavor="es", context="",
            extra_groups=None, alt_text=None, sources=None):
    slots, ms = collect(text, judge, lang, batch, flavor, context,
                        extra_groups, alt_text, sources)
    apply_gates(slots, gate_p, gate_margin, max_changes)
    return rewrite(text, slots), slots, ms


# ---------------------------------------------------------------- CLI
def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("file", nargs="?", help="sentences, one per line (default: stdin)")
    ap.add_argument("--text", help="single sentence")
    ap.add_argument("--judge", default="http://127.0.0.1:8092")
    ap.add_argument("--lang", choices=["es", "en"], default="es")
    ap.add_argument("--gate-p", type=float, default=0.5)
    ap.add_argument("--gate-margin", type=float, default=0.2)
    ap.add_argument("--max-changes", type=int, default=3)
    ap.add_argument("--rewrite", action="store_true",
                    help="apply gated edits to the output text (default: dry run)")
    ap.add_argument("--per-slot", action="store_true",
                    help="one judge request per slot (default: one per sentence)")
    ap.add_argument("--flavor", choices=["es", "en"], default="es",
                    help="instructions language for the judge question")
    ap.add_argument("--ndjson", action="store_true",
                    help="input/output stt-events NDJSON finals")
    ap.add_argument("--context", type=int, default=1,
                    help="previous sentences included as context (default 1)")
    ap.add_argument("--prev", help="previous sentence for --text mode")
    ap.add_argument("--alt", help="alt-engine transcript, one line per input "
                                 "line (engine-disagreement signal)")
    ap.add_argument("--candidates", help="JSON file with lexical-neighbour "
                    "groups: [{'word': 'description', ...}, ...] — every "
                    "candidate needs a semantic description")
    ap.add_argument("--sources", help="comma list of suspicion sources to use: "
                    "confusion-set,lexical-neighbour,engine-disagreement "
                    "(default: all)")
    ap.add_argument("--decisions", help="write decisions NDJSON here (default: stderr)")
    args = ap.parse_args()

    def feed():
        if args.text is not None:
            yield args.text
            return
        f = open(args.file) if args.file else sys.stdin
        for ln in f:            # line-by-line: live streams must flow
            ln = ln.rstrip("\n")
            if ln.strip():
                yield ln

    dec_out = open(args.decisions, "w") if args.decisions else sys.stderr
    lines = feed()
    alt_lines = open(args.alt).read().splitlines() if args.alt else []
    groups = json.load(open(args.candidates)) if args.candidates else None
    sources = set(args.sources.split(",")) if args.sources else None
    history = [args.prev] if args.prev else []
    for n, line in enumerate(lines):
        if args.ndjson:
            try:
                ev = json.loads(line)
            except ValueError:
                print(line, flush=True)  # pass-through: keep the stream valid
                continue
            if ev.get("type") != "final":
                print(line, flush=True)  # start/partial/eof verbatim (stt-events/1)
                continue
            text = ev.get("text", "")
        else:
            text, ev = line, None
        ctx = " ".join(history[-args.context:]) if args.context else ""
        alt = alt_lines[n] if n < len(alt_lines) else None
        try:
            new, slots, ms = correct(text, args.judge, args.lang, args.gate_p,
                                     args.gate_margin, args.max_changes,
                                     batch=not args.per_slot, flavor=args.flavor,
                                     context=ctx, extra_groups=groups,
                                     alt_text=alt, sources=sources)
        except Exception as e:  # judge down/slow: never kill the pipeline
            dec_out.write(json.dumps({"error": "judge: %s" % e,
                                     "text": text}) + "\n")
            dec_out.flush()
            new, slots, ms = text, [], 0.0
        for i, sl in enumerate(slots):
            dec_out.write(json.dumps({
                "slot": i, "word": sl["word"], "candidates": sl["probs"],
                "best": sl["best"], "p": sl["best_p"], "margin": sl["margin"],
                "reason": sl["reason"], "edit": sl["edit"],
                "accepted": sl["accepted"], "why": sl["why"],
                "judge_ms": round(sl["judge_ms"], 1)}, ensure_ascii=False) + "\n")
        dec_out.flush()
        if args.ndjson:
            if args.rewrite:
                ev["text"] = new
            ev["corrections"] = [{"from": s["word"], "to": s["best"],
                                 "p": s["best_p"], "margin": s["margin"]}
                                for s in slots if s["accepted"]]
            print(json.dumps(ev, ensure_ascii=False), flush=True)
        else:
            print(new if args.rewrite else text, flush=True)
        history.append(new if args.rewrite else text)
    if args.decisions:
        dec_out.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
