#!/usr/bin/env python3
"""Fan-out probe for `stt stream --out` (Stage 5, S5.8).

Starts `stt stream --out ADDR`, connects N NDJSON clients before feeding the
PCM, timestamps every line on stdout and on each client, disconnects one
client mid-stream, and reports:

  - stdout/client event lines and arrival times
  - per-event |client_arrival - stdout_arrival| (fan-out overhead)
  - whether all clients received the same events
  - whether the pipeline survived the disconnect (exit code, errors)

Usage:
  python3 tests/fanout_probe.py --stt var/bin/stt \
      --adapter adapters/sherpa/stt-adapter-sherpa \
      --model var/models/sherpa-zipformer-en-kroko \
      --pcm var/tmp/stage5/beckett.raw --speed 2 \
      --addr tcp://127.0.0.1:4799 --clients 2 --report var/tmp/stage5/fanout-tcp.json
"""
import argparse
import json
import socket
import subprocess
import sys
import threading
import time


def connect(addr, timeout=10.0):
    t0 = time.monotonic()
    last = None
    while time.monotonic() - t0 < timeout:
        try:
            if addr.startswith("unix://"):
                s = socket.socket(socket.AF_UNIX)
                s.connect(addr[len("unix://"):])
            else:
                host, port = addr[len("tcp://"):].rsplit(":", 1)
                s = socket.create_connection((host, int(port)), timeout=2)
                s.settimeout(None)  # model load can take >2 s before the first event
            return s
        except OSError as e:
            last = e
            time.sleep(0.02)
    raise RuntimeError(f"cannot connect to {addr}: {last}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stt", required=True)
    ap.add_argument("--adapter", required=True)
    ap.add_argument("--model", default=None)
    ap.add_argument("--pcm", required=True)
    ap.add_argument("--speed", type=float, default=2.0)
    ap.add_argument("--addr", required=True)
    ap.add_argument("--clients", type=int, default=2)
    ap.add_argument("--late-after", type=float, default=2.0,
                    help="connect one extra client this many seconds after feeding starts (0 = off)")
    ap.add_argument("--disconnect-at", type=float, default=0.5,
                    help="disconnect client 0 after this fraction of the feed (0 = never)")
    ap.add_argument("--report", required=True)
    args = ap.parse_args()

    cmd = [args.stt, "stream", "--adapter", args.adapter,
           "--frame-ms", "5000", "--min-segment-ms", "3000",
           "--out", args.addr]
    if args.model:
        cmd += ["--model", args.model]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE)
    start = time.monotonic()

    stdout_lines = []

    def stdout_reader():
        for line in p.stdout:
            line = line.strip()
            if line:
                stdout_lines.append({"t": time.monotonic() - start,
                                     "line": line.decode("utf-8", "replace")})

    th = threading.Thread(target=stdout_reader, daemon=True)
    th.start()

    client_threads = []
    clients = []
    for _ in range(args.clients):
        s = connect(args.addr)
        clients.append({"sock": s, "lines": [], "closed": False})
    late = None
    late_lock = threading.Lock()

    def client_reader(c):
        f = c["sock"].makefile("rb")
        try:
            for line in f:
                line = line.strip()
                if line:
                    c["lines"].append({"t": time.monotonic() - start,
                                       "line": line.decode("utf-8", "replace")})
        except OSError:
            pass
        c["closed"] = True

    for c in clients:
        t = threading.Thread(target=client_reader, args=(c,), daemon=True)
        t.start()
        client_threads.append(t)

    data = open(args.pcm, "rb").read()
    bytes_per_s = 32000
    chunk = int(bytes_per_s * 0.1)
    next_t = start
    sent = 0
    started_late = False
    disconnected = False
    try:
        while sent < len(data):
            n = min(chunk, len(data) - sent)
            p.stdin.write(data[sent:sent + n])
            p.stdin.flush()
            sent += n
            elapsed = (time.monotonic() - start)
            if args.late_after > 0 and not started_late and elapsed >= args.late_after:
                with late_lock:
                    if not started_late:
                        s = connect(args.addr)
                        late = {"sock": s, "lines": [], "closed": False,
                                "connect_at": time.monotonic() - start}
                        t = threading.Thread(target=client_reader, args=(late,),
                                             daemon=True)
                        t.start()
                        client_threads.append(t)
                        started_late = True
            if not disconnected and args.disconnect_at > 0 and \
                    sent >= len(data) * args.disconnect_at:
                try:
                    clients[0]["sock"].shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                clients[0]["sock"].close()
                disconnected = True
            next_t += (0.1 / args.speed)
            delay = next_t - time.monotonic()
            if delay > 0:
                time.sleep(delay)
        if args.late_after > 0 and not started_late:
            with late_lock:
                if not started_late:
                    s = connect(args.addr)
                    late = {"sock": s, "lines": [], "closed": False,
                            "connect_at": time.monotonic() - start}
                    t = threading.Thread(target=client_reader, args=(late,),
                                         daemon=True)
                    t.start()
                    client_threads.append(t)
                    started_late = True
    finally:
        try:
            p.stdin.close()
        except OSError:
            pass

    rc = p.wait(timeout=300)
    th.join(timeout=5)
    # Let every client reader consume the final eof before comparing events.
    for t in client_threads:
        t.join(timeout=5)
    stderr = p.stderr.read().decode("utf-8", "replace")

    # Match stdout lines to each client's lines by exact line content and
    # order. Events are unique enough here (final texts differ).
    by_line = {}
    for e in stdout_lines:
        by_line.setdefault(e["line"], []).append(e["t"])
    overhead = []
    seen = set()
    for c in clients:
        for e in c["lines"]:
            if e["line"] in by_line and e["line"] not in seen:
                seen.add(e["line"])
                # nearest stdout arrival for the same line
                dt = min(abs(e["t"] - t) for t in by_line[e["line"]])
                overhead.append(dt)

    def lines_of(c):
        return [e["line"] for e in c["lines"]]

    identical = True
    if len(clients) >= 2:
        base = lines_of(clients[1])
        identical = all(lines_of(c) == base for c in clients[2:])
        # client 0 was disconnected; it must be a prefix of client 1
        c0 = lines_of(clients[0])
        identical = identical and c0 == base[:len(c0)]
    late_ok = None
    if late:
        ll = lines_of(late)
        base = lines_of(clients[1])
        late_ok = (bool(ll) and '"start"' in ll[0] and len(ll) > 1 and
                   ll[1:] == base[-(len(ll) - 1):])

    events = [json.loads(e["line"]) for e in stdout_lines]
    errors = [e for e in events if e.get("type") == "error"]
    eof = next((e for e in events if e.get("type") == "eof"), None)
    finals = [e for e in events if e.get("type") == "final"]
    report = {
        "addr": args.addr,
        "exit_code": rc,
        "stderr": stderr[-2000:],
        "stdout_events": len(events),
        "finals": len(finals),
        "eof": eof,
        "errors": errors,
        "clients": len(clients),
        "client_events": [len(c["lines"]) for c in clients],
        "identical": identical,
        "disconnected_ok": rc == 0 and not errors,
        "late_client": late_ok,
        "late_client_events": len(late["lines"]) if late else None,
        "overhead_max_s": round(max(overhead), 6) if overhead else None,
        "overhead_p95_s": round(sorted(overhead)[int(0.95 * (len(overhead) - 1))], 6)
        if overhead else None,
        "overhead_samples": len(overhead),
    }
    with open(args.report, "w") as f:
        json.dump({"summary": report, "stdout": stdout_lines,
                   "client_lines": [c["lines"] for c in clients],
                   "late_lines": late["lines"] if late else []}, f)
    print(json.dumps(report, indent=1))
    ok = (rc == 0 and not errors and identical and
          (late_ok is not False) and
          report["overhead_p95_s"] is not None and
          report["overhead_p95_s"] <= 0.010 and
          report["overhead_max_s"] <= 0.050)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
