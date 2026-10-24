# stt-agent-plugin — reference `stt-remote/1` client

Standalone Go module (`stt-client`) implementing the reference client for
an [`sttd`](../../docs/CONTRATOS.md §9) feed, per Spec C (S6.5). It is the
pattern an agent plugin embeds: authenticate, consume finals, survive
reconnects, never surface the same event twice. The CLI wrapper
(`cmd/stt-agent-plugin`) prints every surfaced event as its original NDJSON
line on stdout and diagnostics on stderr.

## Build

```sh
cd clients/agent-plugin
go build -o ../../var/bin/stt-agent-plugin ./cmd/stt-agent-plugin   # vendored deps, offline
```

## CLI

```sh
stt-agent-plugin --url ws://127.0.0.1:4719/v1/feed --token TOKEN \
                 [--partials] [--once] [--query-token] [--quiet]
```

- `--url` feed endpoint (default `ws://127.0.0.1:4719/v1/feed`).
- `--token` bearer token, required (`sttd --print-token` shows it).
- `--partials` also surface `partial` events (default: only `final`).
- `--once` exit 0 after the first `eof` instead of reconnecting for the
  next session.
- `--query-token` send the token as `?token=` instead of the
  `Authorization` header (demonstrates the browser fallback path).
- `--quiet` suppress info diagnostics on stderr (errors always print).

Exit codes: **0** clean end (eof with `--once`, SIGINT/SIGTERM after
printing the one-line summary `events surfaced, duplicates_suppressed,
reconnects`); **2** usage error or HTTP 401 at the handshake — a wrong
token is not retried, `Run` fails fast with `*AuthError`; **1** anything
else.

## Embedding (package `stt-client`, import path `stt-client`)

```go
c := sttclient.New("ws://127.0.0.1:4719/v1/feed", token) // + With* options
err := c.Run(ctx, func(ev sttclient.Event) { fmt.Println(ev.Raw) }) // ~20 lines total
```

Public API: `New(url, token, ...Option)`, `Run(ctx, Handler) error`,
`Stats() Stats{Surfaced, DuplicatesSuppressed, Reconnects}`,
`Event{Type, Text, T0, T1, Raw}`, `Handler func(Event)`, `AuthError`, and
options `WithPartials/WithOnce/WithQueryToken/WithQuiet/WithLogger/WithRand`.

## Behavior notes

- v1 has **no history**: on every (re)connect the server replays `start`
  and only later text follows (docs/OPERACION.md §7.3). The client never
  assumes it recovers missed text; it reconnects automatically (any loss,
  including close 1000 after `eof`, 1001, 1011, 1013) with exponential
  backoff 250 ms → 500 ms → 1 s → 2 s → 5 s cap, ±20 % jitter.
- **Dedupe**: surfaced events are keyed by `(type, t0, t1, text)` in a
  ring of the last 64 keys; anything the transport redelivers is counted
  (`duplicates_suppressed`) and never surfaced.
- `hello` with `"session":null` means lazy attach: the client stays
  connected and logs that it is waiting; `start` arrives when capture
  begins.
- Tests (`plugin_test.go`) run a fake contract server over `httptest` +
  the vendored `github.com/coder/websocket`: no `sttd` binary needed.
  `go test ./...` ≈ 1 s, channel-synchronized, timing assertions only as
  wide bounds (see `TestReconnectBackoff`).
