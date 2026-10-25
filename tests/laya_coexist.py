#!/usr/bin/env python3
"""Coexistence probe: kroko-es STT running while Laya judges (both models resident).

Measures: STT RTF with/without Laya load, Laya decision latency under STT CPU
load, peak RSS of the STT adapter. Evidence: docs/MODELOS.md §6.3 (Sesion 019).
Usage:
  python3 tests/laya_coexist.py --stt-cmd '<command>' [--runs N]
"""
import argparse, json, re, subprocess, threading, time, urllib.request

def decide(url, i, lat):
    state = ("Transcripción parcial de un discurso: «pregunta {WORD%d} puedes hacer tú por tu país». "
             "El reconocedor de voz marcó la palabra entre llaves como dudosa. "
             "¿Cuál es la palabra correcta en ese hueco?" % i)
    body = json.dumps({"state": state, "questions": {"w%d" % i: {
        "type": "choice", "instructions": "Elige la palabra correcta para el hueco.",
        "criteria": {"qué": "interrogativo", "que": "conjunción", "si": "condicional", "sí": "afirmación"}}}}).encode()
    req = urllib.request.Request(url + "/v1/systemone", data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=120) as r:
        json.load(r)
    lat.append((time.monotonic() - t0) * 1000.0)

def rss_kb(pid):
    try:
        with open("/proc/%d/status" % pid) as f:
            for ln in f:
                if ln.startswith("VmHWM"):
                    return int(ln.split()[1])
    except OSError:
        pass
    return 0

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8091")
    ap.add_argument("--stt-cmd", required=True)
    ap.add_argument("--decisions", type=int, default=8)
    ap.add_argument("--runs", type=int, default=2)
    args = ap.parse_args()

    lat = []
    stop = threading.Event()
    def loop():
        i = 0
        while not stop.is_set():
            decide(args.url, i, lat); i += 1
    th = threading.Thread(target=loop); th.start()
    time.sleep(1.0)

    rtfs, walls, stt_hwm = [], [], 0
    for _ in range(args.runs):
        t0 = time.monotonic()
        p = subprocess.run(args.stt_cmd, shell=True, capture_output=True, text=True)
        walls.append(time.monotonic() - t0)
        for ln in p.stdout.splitlines():
            m = re.search(r'"rtf":([0-9.]+)', ln)
            if m:
                rtfs.append(float(m.group(1)))
            m = re.search(r'"rss_kb":([0-9]+)', ln)
            if m:
                stt_hwm = max(stt_hwm, int(m.group(1)))
    stop.set(); th.join()

    print("stt_runs=%d rtf=%s wall=%.1fs stt_peak_rss=%d kB" %
          (len(rtfs), rtfs, sum(walls), stt_hwm))
    if lat:
        lat.sort()
        print("laya_decisions=%d med=%.1f ms p95=%.1f ms max=%.1f ms" %
              (len(lat), lat[len(lat)//2], lat[int(len(lat)*0.95)], lat[-1]))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
