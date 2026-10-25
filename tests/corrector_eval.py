#!/usr/bin/env python3
"""Validation suite for the keyboard-style corrector prototype (MODELOS §6.2).

Cases:
  - real device failures: kroko-es output on tests clip es16k.wav (Kennedy) and
    the whisper-small ES hypothesis recorded in MODELOS §5.1;
  - synthetic ASR errors: one wrong confusable injected into a clean sentence,
    one per confusion set;
  - clean controls: correct sentences with confusable words — the corrector
    must NOT touch them (teclado: never introduce errors).

For every case the judge is queried once (raw probabilities), and the gates
(--gate-p / --gate-margin) are swept OFFLINE to find the operating point.

Usage: python3 tests/corrector_eval.py [--judge http://127.0.0.1:8092]
"""
import argparse, importlib.util, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
spec = importlib.util.spec_from_file_location(
    "stt_correct", os.path.join(ROOT, "scripts", "stt-correct.py"))
sc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sc)

# (id, asr_text, ref_text) — ref == asr when no edit is expected
CASES = [
    # real: kroko-es on var/tmp/es16k.wav (clip Kennedy 5.33 s), 2026-10-25
    ("real-kroko-es",
     "No preguntes si puede hacer tu país por ti, pregunta qué puedes hacer tú por tu país",
     "No preguntes qué puede hacer tu país por ti, pregunta qué puedes hacer tú por tu país"),
    # real: whisper-small hypothesis on the same clip (MODELOS §5.1)
    ("real-whisper-es",
     "Te pregunta que puedes hacer quien por tu país",
     "Te pregunta qué puedes hacer tú por tu país"),
    # synthetic: one wrong confusable each
    ("syn-si-que", "No sé si puedes hacer por tu país.", "No sé qué puedes hacer por tu país."),
    ("syn-esta-esta", "Ya esta claro el problema.", "Ya está claro el problema."),
    ("syn-quien-quien", "No sé quien viene mañana.", "No sé quién viene mañana."),
    ("syn-tu-tu", "Es tú casa la de la esquina.", "Es tu casa la de la esquina."),
    ("syn-aun-aun", "Aun no ha llegado el tren.", "Aún no ha llegado el tren."),
    ("syn-se-se", "Se lo que quieres decir.", "Sé lo que quieres decir."),
    ("syn-mas-mas", "Es mas difícil de lo que parece.", "Es más difícil de lo que parece."),
    ("syn-como-como", "No sé como se hace esto.", "No sé cómo se hace esto."),
    ("syn-el-el", "El vino tarde ayer.", "Él vino tarde ayer."),
    ("syn-hay-ay", "Ay mucha gente en la calle.", "Hay mucha gente en la calle."),
    ("syn-cuando-cuando", "No sé cuando llegas.", "No sé cuándo llegas."),
    ("syn-de-de", "Espero que me de tiempo.", "Espero que me dé tiempo."),
    # clean controls: correct usage, nothing must change
    ("clean-que", "Creo que es importante que vengas.", None),
    ("clean-si", "No sé si vienes o no.", None),
    ("clean-tu", "Tu casa es grande y bonita.", None),
    ("clean-el", "El perro duerme en el sofá.", None),
    ("clean-esta", "Está bien así, no toques nada.", None),
    ("clean-hay", "Hay mucha gente en la calle hoy.", None),
    ("clean-sera", "Sería mejor que vinieras temprano.", None),
    ("clean-para", "Trabajo para ganar dinero.", None),
]


def word_index_map(text):
    return [(s, e, w) for s, e, w in sc.tokenize(text)]


def expected_edits(asr, ref):
    """(word_index, from, to) for single-word substitutions."""
    a, b = word_index_map(asr), word_index_map(ref)
    import difflib
    out = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(
            a=[w for _, _, w in a], b=[w for _, _, w in b],
            autojunk=False).get_opcodes():
        if tag == "replace" and (i2 - i1) == (j2 - j1):
            for k in range(i2 - i1):
                out.append((i1 + k, a[i1 + k][2], b[j1 + k][2]))
    return out


def slot_word_index(text, slot):
    for i, (s, e, w) in enumerate(word_index_map(text)):
        if s == slot["start"]:
            return i
    return -1


def sweep(rows, gate_p, gate_margin, max_changes):
    """rows: (case_id, expected[(idx,from,to)], slots[...]) -> (tp, fp, fn)."""
    tp = fp = fn = 0
    for cid, exp, slots in rows:
        cand = []
        for sl in slots:
            if sl["best"].lower() != sl["word"].lower():
                cand.append(sl)
        cand.sort(key=lambda s: -s["margin"])
        accepted = set()
        for sl in cand[:max_changes]:
            if sl["best_p"] >= gate_p and sl["margin"] >= gate_margin:
                accepted.add(id(sl))
        got = {(slot_word_index(sl["_text"], sl), sl["word"], sl["best"])
               for sl in slots if id(sl) in accepted}
        want = set(exp)
        tp += len(got & want)
        fp += len(got - want)
        fn += len(want - got)
    return tp, fp, fn


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--judge", default="http://127.0.0.1:8092")
    ap.add_argument("--lang", default="es")
    ap.add_argument("--flavor", choices=["es", "en"], default="es")
    ap.add_argument("--max-changes", type=int, default=3)
    ap.add_argument("--dump", help="write raw judge rows to this JSON file")
    args = ap.parse_args()

    rows, lat = [], []
    for cid, asr, ref in CASES:
        t0 = time.monotonic()
        slots, ms = sc.collect(asr, args.judge, args.lang, flavor=args.flavor)
        lat.append((time.monotonic() - t0) * 1000.0)
        for sl in slots:
            sl["_text"] = asr
        exp = expected_edits(asr, ref) if ref and ref != asr else []
        rows.append((cid, exp, slots))
        desc = []
        for sl in slots:
            desc.append("%s->%s p=%.2f m=%.2f%s" % (
                sl["word"], sl["best"], sl["best_p"], sl["margin"],
                " EDIT" if sl["best"].lower() != sl["word"].lower() else ""))
        print("%-18s want=%-28s %s" % (
            cid, ",".join("%s>%s" % (f, t) for _, f, t in exp) or "-",
            " | ".join(desc) or "(no slots)"))

    print("\n-- latency: %d sentences, %.1f s total, %.0f ms/sentence (batch)" %
          (len(rows), sum(lat) / 1000.0, sum(lat) / len(lat)))

    print("\n-- gate sweep (offline; tp=correct edits, fp=wrong edits, "
          "fn=missed):")
    print("%8s %10s %6s %6s %6s %9s" % ("gate_p", "gate_margin", "tp", "fp",
                                        "fn", "precision"))
    best = None
    for gp in (0.30, 0.40, 0.45, 0.50, 0.55, 0.60, 0.70):
        for gm in (0.05, 0.10, 0.20, 0.30):
            tp, fp, fn = sweep(rows, gp, gm, args.max_changes)
            prec = tp / (tp + fp) if (tp + fp) else 1.0
            rec = tp / (tp + fn) if (tp + fn) else 1.0
            print("%8.2f %10.2f %6d %6d %6d %8.0f%% (recall %.0f%%)" %
                  (gp, gm, tp, fp, fn, prec * 100, rec * 100))
            if fp == 0 and (best is None or rec > best[0]):
                best = (rec, gp, gm, tp, fn)
    if best:
        print("\nrecommended operating point (precision 100%% on this suite): "
              "gate_p=%.2f gate_margin=%.2f (recall %.0f%%, tp=%d fn=%d)" %
              (best[1], best[2], best[0] * 100, best[3], best[4]))

    if args.dump:
        with open(args.dump, "w") as f:
            json.dump([{"case": c, "expected": e,
                        "slots": [{k: v for k, v in s.items() if k != "_text"}
                                  for s in s_]} for c, e, s_ in rows], f,
                      ensure_ascii=False, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
