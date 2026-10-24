#!/usr/bin/env python3
"""Minimal RFC 6455 WebSocket client + stt-remote/1 probes (Stage 6).

Pure Python 3 stdlib (socket, base64, hashlib, os, struct, json, argparse,
time, select, sys): no pip dependencies. It performs the HTTP upgrade
handshake (verifying Sec-WebSocket-Accept), then a frame codec where client
frames are masked and server frames are not: text messages, WS ping
auto-replied with pong, close frames reported with their status code.

URL forms: ws://127.0.0.1:PORT/v1/feed and the ?token= fallback (the token
may also go in the Authorization: Bearer header via --token).

Subcommands (small and composable; every assertion failure names itself and
exits 1; exit 2 is usage):

  collect URL    connect and read messages until `eof`, --expect N messages
                 or --timeout S; print one JSON object:
                 {"messages":[<raw strings>], "close":<int|null>,
                  "arrivals_ms":[...], "reason": "..."}
                 (--ready-file F is touched once the connection is up)
  compare A B    two concurrent clients on A and B; assert both receive
                 identical message lists in identical order; report the diff
  churn URL      N connect/read-one-message/disconnect cycles, then --expect
                 M fresh simultaneous connections (proves max_clients slots
                 are released); prints sttd RSS before/after via --pid PID
  slow URL       connect with a tiny SO_RCVBUF (set BEFORE connect), stop
                 reading after the first message; report the close code seen
                 and how long the connection survived (expect 1013)
  status URL     plain HTTP status assertion on the upgrade request
                 (--expect-status 401/503 ...; no WS upgrade happens)

There are no sleeps used for synchronization: every wait is a bounded recv
with a deadline, and timeouts fail loudly.
"""

import argparse
import base64
import hashlib
import json
import os
import select
import socket
import struct
import sys
import time

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

# Frame opcodes (RFC 6455 §5.2).
OP_CONT, OP_TEXT, OP_BINARY, OP_CLOSE, OP_PING, OP_PONG = 0x0, 0x1, 0x2, 0x8, 0x9, 0xA


class ProbeError(Exception):
    """Assertion failure; str(err) names the failing assertion."""


class HTTPStatus(Exception):
    """The server answered the upgrade request with a plain HTTP status."""

    def __init__(self, status, reason, body):
        super().__init__(f"HTTP {status} {reason}")
        self.status = status
        self.reason = reason
        self.body = body


def parse_url(url):
    if not url.startswith("ws://"):
        raise ProbeError(f"assert-url-ws: only ws:// URLs are supported: {url!r}")
    rest = url[len("ws://"):]
    path = "/v1/feed"
    if "/" in rest:
        hostport, path = rest.split("/", 1)
        path = "/" + path
    else:
        hostport = rest
    if ":" not in hostport:
        raise ProbeError(f"assert-url-port: ws URL needs an explicit port: {url!r}")
    host, port = hostport.rsplit(":", 1)
    return host, int(port), path


class WSClient:
    """One RFC 6455 connection: handshake + frame codec."""

    def __init__(self, url, token=None, timeout=10.0, rcvbuf=None):
        self.host, self.port, self.path = parse_url(url)
        self.token = token
        self.timeout = timeout
        self.rcvbuf = rcvbuf
        self.sock = None
        self.buf = b""
        self.t_connect = None
        self.close_sent = False
        self.close_code = None
        self.deadline = None

    # -- handshake ---------------------------------------------------------

    def connect(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        if self.rcvbuf:
            # Deliberately tiny, and set BEFORE connect so it is announced
            # in the SYN: a client that stops reading jams at ~rcvbuf bytes.
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, self.rcvbuf)
        self.sock.settimeout(self.timeout)
        self.sock.connect((self.host, self.port))
        key = base64.b64encode(os.urandom(16)).decode()
        req = [
            f"GET {self.path} HTTP/1.1",
            f"Host: {self.host}:{self.port}",
            "Upgrade: websocket",
            "Connection: Upgrade",
            f"Sec-WebSocket-Key: {key}",
            "Sec-WebSocket-Version: 13",
        ]
        if self.token:
            req.append(f"Authorization: Bearer {self.token}")
        req.append("")
        req.append("")
        self.sock.sendall(("\r\n".join(req)).encode())

        # Read the header block (bounded by the socket timeout).
        while b"\r\n\r\n" not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ProbeError("assert-upgrade: connection closed before the handshake")
            self.buf += chunk
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        lines = head.decode("latin-1").split("\r\n")
        parts = lines[0].split(" ", 2)
        if len(parts) < 2 or not parts[1].isdigit():
            raise ProbeError(f"assert-status-line: malformed status line {lines[0]!r}")
        status = int(parts[1])
        if status != 101:
            raise HTTPStatus(status, parts[2] if len(parts) > 2 else "", head.decode("latin-1"))
        headers = {}
        for ln in lines[1:]:
            if ":" in ln:
                k, v = ln.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        expect = base64.b64encode(
            hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        got = headers.get("sec-websocket-accept", "")
        if got != expect:
            raise ProbeError(
                f"assert-accept: Sec-WebSocket-Accept mismatch: {got!r} != {expect!r}")
        self.t_connect = time.monotonic()
        return self

    # -- frame codec -------------------------------------------------------

    def _recv(self, deadline):
        while True:
            need = self.deadline_left(deadline)
            if need <= 0:
                raise socket.timeout()
            self.sock.settimeout(need)
            chunk = self.sock.recv(65536)
            if not chunk:
                return False  # abrupt EOF
            self.buf += chunk
            return True

    @staticmethod
    def deadline_left(deadline):
        return deadline - time.monotonic()

    def _read_exact(self, n, deadline):
        while len(self.buf) < n:
            if not self._recv(deadline):
                raise ProbeError("assert-frame: connection closed mid-frame")
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send_frame(self, opcode, payload=b""):
        # Client frames are always masked (RFC 6455 §5.3).
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        header = bytes([0x80 | opcode])
        n = len(payload)
        if n < 126:
            header += bytes([0x80 | n])
        elif n < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", n)
        self.sock.sendall(header + mask + masked)

    def recv_message(self, deadline):
        """Return ("text", str) | ("binary", bytes) | ("close", code|None).

        pings are auto-replied with pongs; pongs are ignored; fragmented
        messages are reassembled. Raises socket.timeout past the deadline.
        """
        frags, frag_opcode = [], None
        while True:
            hdr = self._read_exact(2, deadline)
            fin, opcode, masked = bool(hdr[0] & 0x80), hdr[0] & 0x0F, bool(hdr[1] & 0x80)
            n = hdr[1] & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read_exact(2, deadline))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read_exact(8, deadline))[0]
            if masked:
                raise ProbeError("assert-unmasked-server-frame: server frame is masked")
            payload = self._read_exact(n, deadline) if n else b""
            if not fin and opcode in (OP_TEXT, OP_BINARY):
                frags, frag_opcode = [payload], opcode
                continue
            if not fin and opcode == OP_CONT:
                frags.append(payload)
                continue
            if frags and opcode == OP_CONT:
                payload = b"".join(frags) + payload
                opcode = frag_opcode
                frags = []
            if opcode == OP_PING:
                self.send_frame(OP_PONG, payload)
                continue
            if opcode == OP_PONG:
                continue
            if opcode == OP_CLOSE:
                code = None
                if len(payload) >= 2:
                    code = struct.unpack(">H", payload[:2])[0]
                if not self.close_sent:
                    self.send_frame(OP_CLOSE, payload[:2])
                    self.close_sent = True
                self.close_code = code
                return ("close", code)
            if opcode == OP_TEXT:
                return ("text", payload.decode("utf-8", "replace"))
            if opcode == OP_BINARY:
                return ("binary", payload)
            raise ProbeError(f"assert-opcode: unexpected opcode {opcode:#x}")

    def close(self, code=1000, deadline=None):
        """Send a close frame and wait (bounded) for the peer's echo."""
        if self.sock is None:
            return None
        if not self.close_sent:
            payload = struct.pack(">H", code)
            try:
                self.send_frame(OP_CLOSE, payload)
                self.close_sent = True
            except OSError:
                pass
        if deadline is None:
            deadline = time.monotonic() + 5.0
        try:
            while True:
                kind, val = self.recv_message(deadline)
                if kind == "close":
                    return val
        except (ProbeError, socket.timeout, OSError):
            return None
        finally:
            try:
                self.sock.close()
            except OSError:
                pass

    def abort(self):
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None


def is_eof(msg):
    try:
        return json.loads(msg).get("type") == "eof"
    except (json.JSONDecodeError, ValueError):
        return False


# -- collect ---------------------------------------------------------------

def collect_one(url, token=None, expect=None, timeout=10.0, ready_file=None,
                require_eof=False, quiet=False):
    """Connect and read until eof / expect / timeout; return the result dict."""
    c = WSClient(url, token=token, timeout=timeout).connect()
    if ready_file:
        with open(ready_file, "w") as f:
            f.write(str(os.getpid()))
    messages, arrivals = [], []
    close_code, reason = None, "timeout"
    deadline = time.monotonic() + timeout
    try:
        while True:
            left = c.deadline_left(deadline)
            if left <= 0:
                break
            kind, val = c.recv_message(deadline)
            if kind == "text":
                messages.append(val)
                arrivals.append(round((time.monotonic() - c.t_connect) * 1000, 3))
                if expect is not None and len(messages) >= expect:
                    reason = "expect"
                    break
                if is_eof(val):
                    reason = "eof"
                    # Keep reading (bounded): the server closes right after.
                    deadline = min(deadline, time.monotonic() + 5.0)
            elif kind == "binary":
                messages.append(val.decode("utf-8", "replace"))
                arrivals.append(round((time.monotonic() - c.t_connect) * 1000, 3))
            elif kind == "close":
                close_code, reason = val, "close"
                break
    except socket.timeout:
        pass
    finally:
        if reason != "close":
            close_code = c.close(deadline=time.monotonic() + 3.0)
        c.abort()
    result = {"messages": messages, "close": close_code,
              "arrivals_ms": arrivals, "reason": reason}
    if expect is not None and len(messages) < expect:
        raise ProbeError(
            f"assert-expect: expected {expect} messages, got {len(messages)} "
            f"(stop reason: {reason})")
    if require_eof and not (messages and is_eof(messages[-1])):
        raise ProbeError(
            "assert-eof-last: stream ended without eof as last message "
            f"(reason: {reason}, last: {messages[-1:]!r})")
    if not quiet:
        print(json.dumps(result))
    return result


# -- compare ---------------------------------------------------------------

def run_compare(url_a, url_b, token=None, timeout=15.0):
    import threading
    out = {}

    def worker(key, url):
        try:
            out[key] = collect_one(url, token=token, timeout=timeout, quiet=True)
        except (ProbeError, HTTPStatus, OSError) as e:
            out[key] = {"error": str(e)}

    ta = threading.Thread(target=worker, args=("a", url_a))
    tb = threading.Thread(target=worker, args=("b", url_b))
    ta.start(); tb.start(); ta.join(); tb.join()

    a, b = out.get("a", {}), out.get("b", {})
    ma, mb = a.get("messages", []), b.get("messages", [])
    identical = ma == mb and bool(ma)
    first_diff = None
    if not identical:
        for i in range(max(len(ma), len(mb))):
            xa = ma[i] if i < len(ma) else None
            xb = mb[i] if i < len(mb) else None
            if xa != xb:
                first_diff = {"index": i, "a": xa, "b": xb}
                break
    report = {
        "identical": identical,
        "count_a": len(ma), "count_b": len(mb),
        "close_a": a.get("close"), "close_b": b.get("close"),
        "error_a": a.get("error"), "error_b": b.get("error"),
        "first_diff": first_diff,
    }
    print(json.dumps(report))
    if a.get("error"):
        raise ProbeError(f"assert-client-a: {a['error']}")
    if b.get("error"):
        raise ProbeError(f"assert-client-b: {b['error']}")
    if not identical:
        raise ProbeError(
            f"assert-identical: clients received different message streams "
            f"({len(ma)} vs {len(mb)} messages); first diff: {json.dumps(first_diff)}")
    return report


# -- churn -----------------------------------------------------------------

def rss_kb(pid):
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1])
    except OSError:
        pass
    return None


def run_churn(url, cycles, expect, token=None, timeout=10.0, pid=None):
    rss_before = rss_kb(pid) if pid else None
    cycle_ms = []
    for i in range(cycles):
        t0 = time.monotonic()
        try:
            c = WSClient(url, token=token, timeout=timeout).connect()
            kind, val = c.recv_message(time.monotonic() + timeout)
            if kind != "text":
                raise ProbeError(
                    f"assert-churn-hello: cycle {i}: no hello message (got {kind} {val})")
            c.abort()  # plain disconnect: exercises the server's cleanup path
        except HTTPStatus as e:
            raise ProbeError(
                f"assert-churn-connect: cycle {i}: refused with HTTP {e.status}")
        cycle_ms.append(round((time.monotonic() - t0) * 1000, 3))
    # Fresh simultaneous connections: the slots must all be free again.
    fresh = []
    try:
        for _ in range(expect):
            fresh.append(WSClient(url, token=token, timeout=timeout).connect())
        hellos = 0
        deadline = time.monotonic() + timeout
        for c in fresh:
            kind, _ = c.recv_message(deadline)
            if kind == "text":
                hellos += 1
    finally:
        for c in fresh:
            c.abort()
    rss_after = rss_kb(pid) if pid else None
    report = {"cycles": cycles, "cycle_ms": cycle_ms, "fresh_expected": expect,
              "fresh_ok": hellos, "rss_before_kb": rss_before, "rss_after_kb": rss_after}
    print(json.dumps(report))
    if hellos != expect:
        raise ProbeError(
            f"assert-slots-released: only {hellos}/{expect} fresh clients could "
            f"connect simultaneously after {cycles} churn cycles")
    return report


# -- slow ------------------------------------------------------------------

def run_slow(url, token=None, timeout=20.0, expect_close=1013):
    """Tiny SO_RCVBUF, read the first message, then stop reading.

    With the receive window jammed, the server's slow-client path (queue
    overflow -> 1013) tears the connection down. The teardown is detected
    without consuming a single byte (POLLRDHUP / TCP close-wait state, both
    observable while unread data is still buffered); only afterwards is the
    buffer drained to look for a close frame. A fully jammed client can be
    sent no close frame (its window is shut), so an abrupt teardown is a
    valid observation: the server-side 1013 decision is then evidenced by
    sttd's own log; when a frame IS visible it must equal --expect-close.
    """
    POLLIN, POLLHUP, POLLERR = 1, 16, 8
    POLLRDHUP = 0x2000  # Linux: peer shut down its writing side
    c = WSClient(url, token=token, timeout=timeout, rcvbuf=4096).connect()
    t0 = c.t_connect
    kind, _ = c.recv_message(time.monotonic() + timeout)  # hello
    if kind != "text":
        raise ProbeError(f"assert-slow-hello: first message was {kind}, not text")

    teardown, survived_ms = False, None
    deadline = time.monotonic() + timeout
    fd = c.sock.fileno()
    poller = select.poll()
    poller.register(fd, POLLHUP | POLLERR | POLLRDHUP)
    while time.monotonic() < deadline:
        left_ms = max(1, int((deadline - time.monotonic()) * 1000))
        events = poller.poll(left_ms)
        if events and (events[0][1] & (POLLHUP | POLLERR | POLLRDHUP)):
            teardown, survived_ms = True, round((time.monotonic() - t0) * 1000, 3)
            break
        state = c.sock.getsockopt(socket.IPPROTO_TCP, 11, 1)[0]  # TCP_INFO: tcpi_state
        if state != 1:  # not ESTABLISHED (e.g. CLOSE_WAIT = peer closed)
            teardown, survived_ms = True, round((time.monotonic() - t0) * 1000, 3)
            break
    if not teardown:
        # Linux with default tcp_wmem: once the client's receive window is
        # shut, the drop's close frame and FIN sit queued behind up to ~4 MiB
        # of undeliverable data in the server's send buffer (lingering close,
        # no RST), so neither POLLRDHUP nor a TCP state change is observable
        # without consuming bytes. Hunt for the teardown by draining
        # (bounded): a dropped client runs into the server's FIN after its
        # queued events (close frame if it got written, else a bare EOF =
        # abrupt); a client that was NOT dropped runs into the eof event
        # first and fails the assert below.
        c.sock.settimeout(5.0)
        drain_deadline = time.monotonic() + 15.0
        try:
            while time.monotonic() < drain_deadline:
                chunk = c.sock.recv(65536)
                if not chunk:
                    teardown, survived_ms = True, round((time.monotonic() - t0) * 1000, 3)
                    break
                c.buf += chunk
        except OSError:
            pass
    if not teardown:
        c.abort()
        raise ProbeError(
            f"assert-slow-dropped: slow client still connected after "
            f"{timeout}s (queue never overflowed?)")

    # Teardown seen; drain the buffered bytes hunting for a close frame.
    close_code, drained, saw_eof = None, 0, False
    try:
        c.sock.settimeout(2.0)
        while True:
            chunk = c.sock.recv(65536)
            if not chunk:
                break
            c.buf += chunk
    except OSError:
        pass
    try:
        d = time.monotonic() + 2.0
        while True:
            kind, val = c.recv_message(d)
            if kind == "text":
                drained += 1
                saw_eof = saw_eof or is_eof(val)
            elif kind == "close":
                close_code = val
                break
    except (ProbeError, socket.timeout, OSError):
        pass
    finally:
        c.abort()
    report = {"close": close_code, "abrupt": close_code is None,
              "expected_close": expect_close, "survived_ms": survived_ms,
              "drained_events": drained, "saw_eof": saw_eof}
    print(json.dumps(report))
    if saw_eof:
        raise ProbeError(
            f"assert-slow-dropped-before-eof: slow client received the eof "
            f"event before being dropped (survived {survived_ms} ms)")
    if close_code is not None and close_code != expect_close:
        raise ProbeError(
            f"assert-slow-close-code: expected close {expect_close}, "
            f"got {close_code} (survived {survived_ms} ms)")
    return report


# -- status ----------------------------------------------------------------

def run_status(url, token=None, expect_status=None, timeout=10.0):
    try:
        WSClient(url, token=token, timeout=timeout).connect()
    except HTTPStatus as e:
        report = {"status": e.status, "reason": e.reason, "upgraded": False}
        print(json.dumps(report))
        if expect_status is not None and e.status != expect_status:
            raise ProbeError(
                f"assert-status: expected HTTP {expect_status}, got {e.status}")
        return report
    raise ProbeError(
        f"assert-status: expected a plain HTTP {expect_status} rejection, "
        "but the upgrade completed")


# -- CLI -------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(prog="ws_probe.py", add_help=True,
                                 description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="mode", required=True)

    p = sub.add_parser("collect", help="connect and collect messages")
    p.add_argument("url")
    p.add_argument("--token", default=None)
    p.add_argument("--no-token", action="store_true",
                   help="explicitly connect without credentials")
    p.add_argument("--expect", type=int, default=None,
                   help="stop after N messages (assert at least N arrive)")
    p.add_argument("--timeout", type=float, default=10.0)
    p.add_argument("--require-eof", action="store_true",
                   help="assert the last message is an eof event")
    p.add_argument("--ready-file", default=None,
                   help="touch this file once the connection is up")

    p = sub.add_parser("compare", help="two clients must see identical streams")
    p.add_argument("url_a")
    p.add_argument("url_b")
    p.add_argument("--token", default=None)
    p.add_argument("--timeout", type=float, default=15.0)

    p = sub.add_parser("churn", help="N connect/disconnect cycles, then M fresh")
    p.add_argument("url")
    p.add_argument("--churn", type=int, default=20)
    p.add_argument("--expect", type=int, default=2,
                   help="fresh simultaneous connections after the churn")
    p.add_argument("--token", default=None)
    p.add_argument("--timeout", type=float, default=10.0)
    p.add_argument("--pid", type=int, default=None,
                   help="sttd pid: report RSS before/after")

    p = sub.add_parser("slow", help="tiny rcvbuf; expect the 1013 slow drop")
    p.add_argument("url")
    p.add_argument("--token", default=None)
    p.add_argument("--timeout", type=float, default=20.0)
    p.add_argument("--expect-close", type=int, default=1013,
                   help="assert this code when a close frame is visible at all")

    p = sub.add_parser("status", help="assert a plain HTTP rejection status")
    p.add_argument("url")
    p.add_argument("--token", default=None)
    p.add_argument("--no-token", action="store_true")
    p.add_argument("--expect-status", type=int, default=None)
    p.add_argument("--timeout", type=float, default=10.0)

    args = ap.parse_args(argv)
    try:
        if args.mode == "collect":
            collect_one(args.url, token=args.token, expect=args.expect,
                        timeout=args.timeout, ready_file=args.ready_file,
                        require_eof=args.require_eof)
        elif args.mode == "compare":
            run_compare(args.url_a, args.url_b, token=args.token, timeout=args.timeout)
        elif args.mode == "churn":
            run_churn(args.url, args.churn, args.expect, token=args.token,
                      timeout=args.timeout, pid=args.pid)
        elif args.mode == "slow":
            run_slow(args.url, token=args.token, timeout=args.timeout,
                     expect_close=args.expect_close)
        elif args.mode == "status":
            run_status(args.url, token=args.token, expect_status=args.expect_status,
                       timeout=args.timeout)
    except ProbeError as e:
        print(f"ws_probe: FAIL {e}", file=sys.stderr)
        return 1
    except HTTPStatus as e:
        print(f"ws_probe: FAIL unexpected HTTP status: {e}", file=sys.stderr)
        return 1
    except (socket.timeout, OSError) as e:
        print(f"ws_probe: FAIL transport error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
