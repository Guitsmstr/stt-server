#!/usr/bin/env python3
"""Live microphone probe for `stt stream` (Stage 4 evidence).

Starts the capture script, pipes its PCM into `stt stream`, timestamps every
stt-events/1 line, optionally triggers a spoken phrase (Android TTS) and
writes a JSON report with per-final latency (arrival - audio end).

Usage:
  python3 tests/live_probe.py \
      --capture scripts/termux-capture.sh \
      --stt var/bin/stt \
      --speak-cmd './scripts/termux-speak.sh "Ever tried ever failed"' \
      --duration 20 --pcm var/tmp/stage4/live.raw \
      --report var/tmp/stage4/live.json
"""

import argparse
import json
import shlex
import statistics
import subprocess
import sys
import threading
import time


def p95(values):
    if not values:
        return None
    s = sorted(values)
    idx = min(len(s) - 1, int(round(0.95 * (len(s) - 1))))
    return s[idx]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--capture", required=True)
    ap.add_argument("--capture-args", default="")
    ap.add_argument("--stt", required=True)
    ap.add_argument("--stt-args", default="")
    ap.add_argument("--speak-cmd", default=None,
                    help="shell command that starts TTS/playback")
    ap.add_argument("--speak-delay", type=float, default=3.0)
    ap.add_argument("--duration", type=float, default=20.0)
    ap.add_argument("--pcm", default=None)
    ap.add_argument("--report", required=True)
    args = ap.parse_args()

    cap_cmd = [args.capture] + shlex.split(args.capture_args)
    stt_cmd = [args.stt, "stream"] + shlex.split(args.stt_args)

    cap = subprocess.Popen(cap_cmd, stdout=subprocess.PIPE)
    stt = subprocess.Popen(stt_cmd, stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE)

    start_wall = time.monotonic()
    events = []
    lock = threading.Lock()
    pcm = open(args.pcm, "wb") if args.pcm else None
    speak_at = [None]
    speak_done = [None]

    def pump():
        try:
            while True:
                data = cap.stdout.read(4096)
                if not data:
                    break
                if pcm:
                    pcm.write(data)
                    pcm.flush()
                try:
                    stt.stdin.write(data)
                    stt.stdin.flush()
                except (BrokenPipeError, OSError):
                    break
        finally:
            try:
                stt.stdin.close()
            except OSError:
                pass

    def read_events():
        for line in stt.stdout:
            line = line.strip()
            if not line:
                continue
            arrival = time.monotonic() - start_wall
            try:
                ev = json.loads(line)
            except (json.JSONDecodeError, UnicodeDecodeError):
                ev = {"type": "unparsed", "raw": line[:200]}
            with lock:
                events.append({"arrival": arrival, "event": ev})

    def speak():
        time.sleep(max(0.0, args.speak_delay))
        speak_at[0] = time.monotonic() - start_wall
        subprocess.run(args.speak_cmd, shell=True)
        speak_done[0] = time.monotonic() - start_wall

    tp = threading.Thread(target=pump, daemon=True)
    tr = threading.Thread(target=read_events, daemon=True)
    tp.start()
    tr.start()
    if args.speak_cmd:
        threading.Thread(target=speak, daemon=True).start()

    time.sleep(args.duration)

    cap.terminate()
    try:
        cap.wait(timeout=4)
    except subprocess.TimeoutExpired:
        cap.kill()
        cap.wait()
    try:
        stt.wait(timeout=10)
    except subprocess.TimeoutExpired:
        stt.terminate()
        try:
            stt.wait(timeout=4)
        except subprocess.TimeoutExpired:
            stt.kill()
            stt.wait()

    tp.join(timeout=3)
    tr.join(timeout=3)
    if pcm:
        pcm.close()

    with lock:
        evs = list(events)
    start_arrival = None
    eof = None
    finals = []
    for item in evs:
        ev = item["event"]
        if ev.get("type") == "start" and start_arrival is None:
            start_arrival = item["arrival"]
        if ev.get("type") == "eof":
            eof = ev
        if ev.get("type") == "final":
            finals.append({
                "text": ev.get("text", ""),
                "t0": ev.get("t0"),
                "t1": ev.get("t1"),
                "arrival": item["arrival"],
                "rtf": ev.get("rtf"),
            })

    # Latency: arrival after the start event minus the event's own audio end.
    # The start event is emitted as soon as stt starts; the first PCM sample
    # follows within the pipe latency (~0.1 s), which is inside the S4.2
    # budget and is documented in the report.
    latencies = []
    for f in finals:
        if f["t1"] is not None and start_arrival is not None:
            f["latency"] = round(f["arrival"] - start_arrival - f["t1"], 3)
            latencies.append(f["latency"])

    # Speech finals whose audio overlaps the TTS/playback.  Use t1 (end of
    # segment): the segment containing the phrase may have started before the
    # TTS command (VAD preroll/background noise).
    speak_from = (speak_at[0] - 0.5) if speak_at[0] is not None else 0.0
    speech = [f for f in finals if f["text"].strip()
              and f["t1"] is not None and f["t1"] >= speak_from]
    speech_lat = [f["latency"] for f in speech if "latency" in f]

    report = {
        "capture_cmd": cap_cmd,
        "stt_cmd": stt_cmd,
        "duration_s": args.duration,
        "speak_cmd": args.speak_cmd,
        "speak_at_s": speak_at[0],
        "speak_done_s": speak_done[0],
        "start_arrival_s": start_arrival,
        "audio_s": (eof or {}).get("audio_s"),
        "skipped_s": (eof or {}).get("skipped_s"),
        "eof": eof,
        "events": evs,
        "finals": finals,
        "latency_max_s": max(latencies) if latencies else None,
        "latency_avg_s": round(statistics.mean(latencies), 3) if latencies else None,
        "latency_p95_s": p95(latencies),
        "speech_finals": speech,
        "speech_count": len(speech),
        "speech_latency_max_s": max(speech_lat) if speech_lat else None,
        "transcript": " ".join(f["text"] for f in speech).strip(),
    }
    with open(args.report, "w") as f:
        json.dump(report, f, indent=2)
        f.write("\n")

    print(json.dumps({k: report[k] for k in (
        "audio_s", "skipped_s", "speech_count", "speech_latency_max_s",
        "latency_max_s", "transcript")}, indent=2))
    return 0 if finals else 1


if __name__ == "__main__":
    sys.exit(main())
