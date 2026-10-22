#!/usr/bin/env python3
"""Paced PCM feeder and probe for `stt stream` (Stage 3 evidence).

Feeds a raw PCM file to `stt stream` at a given speed (1.0 = real time),
timestamps every stt-events/1 line as it arrives on stdout, samples the RSS
of the nucleus and its adapter subprocess, and writes a JSON report with:

  events               every event with arrival time (s since feed start)
  finals               final events + latency vs their own audio end (t1)
  boundary_latency     for every frame boundary covered by speech: how long
                       after the boundary the covering final arrived
                       (S3.2 metric; only meaningful at --speed 1)
  rss                  RSS samples of nucleus and adapter (kB)
  summary              counts and max/avg latencies, RSS drift, etc.

Usage example:
  python3 tests/feed_stream.py --stt var/bin/stt \
      --adapter adapters/moonshine/stt-adapter-moonshine \
      --model var/models/moonshine-tiny \
      --pcm var/tmp/stage3/stream5min.pcm --speed 1 --report /tmp/report.json
"""

import argparse
import json
import os
import subprocess
import sys
import threading
import time


def rss_kb(pid):
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1])
    except OSError:
        pass
    return None


def children_pids(pid):
    out = []
    try:
        for t in os.listdir(f"/proc/{pid}/task"):
            with open(f"/proc/{pid}/task/{t}/children") as f:
                out += [int(x) for x in f.read().split()]
    except OSError:
        pass
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stt", required=True)
    ap.add_argument("--adapter", required=True)
    ap.add_argument("--model", default=None)
    ap.add_argument("--pcm", required=True)
    ap.add_argument("--speed", type=float, default=1.0)
    ap.add_argument("--chunk-ms", type=float, default=100.0)
    ap.add_argument("--frame-ms", type=int, default=2000)
    ap.add_argument("--vad", default="true")
    ap.add_argument("--partials", action="store_true")
    ap.add_argument("--report", required=True)
    args = ap.parse_args()

    bytes_per_s = 32000  # 16 kHz mono s16le
    chunk = int(bytes_per_s * args.chunk_ms / 1000)
    chunk_s = args.chunk_ms / 1000.0

    cmd = [args.stt, "stream", "--adapter", args.adapter,
           f"--vad={args.vad}", f"--frame-ms={args.frame_ms}"]
    if args.model:
        cmd += ["--model", args.model]
    if args.partials:
        cmd += ["--partials=true"]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=None)

    events = []  # {arrival, event}
    start = time.monotonic()

    def reader():
        for line in p.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except (json.JSONDecodeError, UnicodeDecodeError):
                ev = {"type": "unparsed", "raw": line[:200]}
            events.append({"arrival": time.monotonic() - start, "event": ev})

    def sampler():
        samples = []
        while not stop.is_set() or p.poll() is None:
            nuc = rss_kb(p.pid)
            kids = children_pids(p.pid)
            ad = rss_kb(kids[0]) if kids else None
            samples.append({"t": round(time.monotonic() - start, 2),
                            "nucleus_kb": nuc, "adapter_kb": ad})
            stop.wait(1.0)
        return samples

    stop = threading.Event()
    thread = threading.Thread(target=reader, daemon=True)
    thread.start()
    samples = []
    st = threading.Thread(target=lambda: samples.extend(sampler()), daemon=True)
    st.start()

    # Paced feed (binary pipes: PCM bytes in, NDJSON bytes out).
    data = open(args.pcm, "rb").read()
    next_t = start
    sent = 0
    try:
        while sent < len(data):
            n = min(chunk, len(data) - sent)
            p.stdin.write(data[sent:sent + n])
            p.stdin.flush()
            sent += n
            next_t += chunk_s / args.speed
            delay = next_t - time.monotonic()
            if delay > 0:
                time.sleep(delay)
    except BrokenPipeError:
        print("feed_stream: stt closed stdin early", file=sys.stderr)
    finally:
        try:
            p.stdin.close()
        except OSError:
            pass
    rc = p.wait(timeout=300)
    thread.join(timeout=5)
    stop.set()
    st.join(timeout=5)

    # Derived metrics.
    finals = [e for e in events if e["event"].get("type") == "final"]
    errors = [e for e in events if e["event"].get("type") == "error"]
    eof = next((e["event"] for e in events if e["event"].get("type") == "eof"), None)

    fin_lat = [e["arrival"] - e["event"].get("t1", 0.0) for e in finals]
    max_t1 = max((e["event"].get("t1", 0.0) for e in finals), default=0.0)
    b_lat = []
    b = args.frame_ms / 1000.0
    while b <= max_t1:
        # boundary covered by speech? a final spans it
        if any(e["event"].get("t0", 0) < b <= e["event"].get("t1", 0) for e in finals):
            covering = [e["arrival"] - b for e in finals if e["event"].get("t1", 0) >= b]
            if covering:
                b_lat.append(min(covering))
        b += args.frame_ms / 1000.0

    rss_nuc = [s["nucleus_kb"] for s in samples if s["nucleus_kb"]]
    q = max(1, len(rss_nuc) // 4)
    summary = {
        "exit_code": rc,
        "speed": args.speed,
        "audio_s": len(data) / bytes_per_s,
        "wall_s": round(time.monotonic() - start, 2),
        "finals": len(finals),
        "errors": [{"code": e["event"].get("code"), "fatal": e["event"].get("fatal"),
                    "message": e["event"].get("message")} for e in errors],
        "eof": eof,
        "latency_final_max_s": round(max(fin_lat), 3) if fin_lat else None,
        "latency_final_avg_s": round(sum(fin_lat) / len(fin_lat), 3) if fin_lat else None,
        "latency_boundary_max_s": round(max(b_lat), 3) if b_lat else None,
        "boundaries_checked": len(b_lat),
        "nucleus_rss_max_kb": max(rss_nuc) if rss_nuc else None,
        "nucleus_rss_first_quarter_max_kb": max(rss_nuc[:q]) if rss_nuc else None,
        "nucleus_rss_last_quarter_max_kb": max(rss_nuc[-q:]) if rss_nuc else None,
    }

    report = {
        "summary": summary,
        "events": events,
        "finals": [{"t0": e["event"].get("t0"), "t1": e["event"].get("t1"),
                    "text": e["event"].get("text", ""), "arrival": round(e["arrival"], 3),
                    "latency_s": round(e["arrival"] - e["event"].get("t1", 0), 3)}
                   for e in finals],
        "rss": samples,
    }
    with open(args.report, "w") as f:
        json.dump(report, f)
    print(json.dumps(summary, indent=1))
    return 0 if rc == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
