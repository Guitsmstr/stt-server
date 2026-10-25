#!/usr/bin/env python3
"""Probe: Laya as word-level judge for the keyboard-style corrector (MODELOS §6.2).

Cases are the recorded ASR failures of this project (MODELOS §5.1):
  - ES kroko: "si" (true: "que/que")
  - ES whisper: "que ... quien por" (true: "que ... tu por")
  - EN kroko/whisper: "fell better" (true: "fail better")
Each case runs as `choice` (pick candidate) and `noul` (is the ASR word wrong?).
Plus semantic routing/urgency controls (es/en) to check coarse decisions.

Works against any TypeSafe `/v1/systemone` server: llama.cpp (ggml-org
Laya-GGUF) or `laya serve` (mys/laya-multilingual-GGUF). Evidence and
readings: docs/MODELOS.md §6.3 (Sesion 019).
Usage: python3 tests/laya_probe.py [--url http://127.0.0.1:8092] [--reps N]
"""
import argparse, json, statistics, sys, time, urllib.request

def ask(url, state, questions):
    body = json.dumps({"state": state, "questions": questions}).encode()
    req = urllib.request.Request(url + "/v1/systemone", data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=60) as r:
        out = json.load(r)
    return out, (time.monotonic() - t0) * 1000.0

CASES = [
    # --- ES: word choice in the marked slot (candidatos del confusion set) ---
    ("es_choice_que",
     "Transcripción parcial de un discurso: «pregunta {WORD} puedes hacer tú por tu país». "
     "El reconocedor de voz marcó la palabra entre llaves como dudosa. "
     "¿Cuál es la palabra correcta en ese hueco?",
     {"type": "choice", "instructions": "Elige la palabra correcta para el hueco.",
      "criteria": {"qué": "interrogativo o exclamativo", "que": "conjunción",
                   "si": "condicional", "sí": "afirmación"}}),
    ("es_choice_tu",
     "Transcripción parcial de un discurso: «la pregunta qué puedes hacer {WORD} por tu país». "
     "El reconocedor de voz marcó la palabra entre llaves como dudosa. "
     "¿Cuál es la palabra correcta en ese hueco?",
     {"type": "choice", "instructions": "Elige la palabra correcta para el hueco.",
      "criteria": {"tú": "pronombre personal", "tu": "posesivo",
                   "quién": "interrogativo", "el": "artículo"}}),
    ("es_noul_si",
     "Transcripción de voz a texto: «No sé si puedes hacer por tu país». "
     "La palabra «si» proviene del reconocedor y puede ser un error de detección.",
     {"type": "noul", "instructions": "¿Es errónea la palabra «si» en ese contexto?"}),
    # --- EN: same judge task (control: the checkpoint is English-first) ---
    ("en_choice_fail",
     "Partial transcript of a speech: <<Ever tried. Ever failed. {WORD} better.>> "
     "The speech recognizer marked the braced word as uncertain. "
     "Which word belongs in that slot?",
     {"type": "choice", "instructions": "Pick the correct word for the slot.",
      "criteria": {"fail": "to not succeed", "fell": "past of fall", "feel": "to sense"}}),
    ("en_noul_fell",
     "Speech recognizer transcript: <<Ever tried. Ever failed. No matter. Try again. "
     "Fail again. Feel better.>> The word 'Feel' comes from the recognizer.",
     {"type": "noul", "instructions": "Is the word 'Feel' wrong in this context?"}),
    # --- semantic sanity: routing (both languages) ---
    ("es_route",
     "Mensaje del cliente: «Hola, nos cobraron dos veces el mes de marzo. "
     "Por favor reembolsen el cobro duplicado hoy o cancelaremos el plan.»",
     {"type": "choice", "instructions": "¿Qué equipo debe gestionar esto?",
      "criteria": {"facturación": "cobros, pagos, reembolsos",
                   "técnico": "fallos, caídas, errores de sistema",
                   "otro": "todo lo demás"}}),
    ("en_route",
     "Customer message: <<Hi, we were billed twice for March. "
     "Please refund the duplicate today or we will cancel our plan.>>",
     {"type": "choice", "instructions": "Which team should handle this?",
      "criteria": {"billing": "invoices, payments, refunds",
                   "technical": "bugs, outages, system errors",
                   "other": "everything else"}}),
    ("es_urgency",
     "Mensaje del cliente: «Hola, nos cobraron dos veces el mes de marzo. "
     "Reembolsen hoy o cancelaremos el plan.»",
     {"type": "score", "instructions": "¿Qué urgencia tiene?",
      "criteria": ["puede esperar", "esta semana", "hoy", "ahora mismo"]}),
]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8091")
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    rows = []
    for name, state, q in CASES:
        lat, first = [], None
        for i in range(args.reps):
            out, ms = ask(args.url, state, {name: q})
            lat.append(ms)
            if first is None:
                first = out["answers"][name]
        ans = first
        if ans.get("type") == "choice" or "choice" in ans:
            detail = "choice=%s conf=%.3f p=%s" % (
                ans["choice"], ans.get("confidence", 0),
                json.dumps(ans.get("probabilities", {}), ensure_ascii=False))
        elif "noul" in ans:
            detail = "noul=%.4f" % ans["noul"]
        else:
            detail = "score=%.3f conf=%.3f" % (ans["score"], ans.get("confidence", 0))
        rows.append((name, detail, statistics.median(lat), max(lat)))
        print("%-16s %-70s med=%6.1f ms max=%6.1f ms" % (name, detail, statistics.median(lat), max(lat)))
    if args.json:
        print(json.dumps(rows))
    return 0

if __name__ == "__main__":
    sys.exit(main())
