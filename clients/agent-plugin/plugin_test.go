// Deterministic tests for the reference stt-remote/1 client: a fake server
// speaking the contract (docs/CONTRATOS.md §9) over httptest + the vendored
// github.com/coder/websocket — no sttd binary involved. Synchronization is
// channel/callback based with generous deadlines; the only timing
// assertions are the wide backoff bounds of TestReconnectBackoff.
package sttclient_test

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"math/rand"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	sttclient "stt-client"

	"github.com/coder/websocket"
)

// Fixture lines exactly as sttd would send them (contract §9.3).
const (
	helloActive = `{"type":"hello","protocol":"stt-remote/1","server":"sttd/0.1","session":{"id":"20261023-1","engine":"moonshine-tiny","partials":true,"started_at":"2026-10-23T19:31:02Z","audio":{"rate":16000,"channels":1,"format":"s16le"}}}`
	helloIdle   = `{"type":"hello","protocol":"stt-remote/1","server":"sttd/0.1","session":null}`
	startLine   = `{"type":"start","audio":{"rate":16000,"channels":1,"format":"s16le"}}`
	eofLine     = `{"type":"eof","frames":1,"audio_s":2.5,"rss_kb":262968}`
)

// helloWith builds a hello line naming session id (the fixture sessions
// are otherwise identical), so tests can span distinct sessions.
func helloWith(id string) string {
	return fmt.Sprintf(`{"type":"hello","protocol":"stt-remote/1","server":"sttd/0.1","session":{"id":%q,"engine":"moonshine-tiny","partials":true,"started_at":"2026-10-23T19:31:02Z","audio":{"rate":16000,"channels":1,"format":"s16le"}}}`, id)
}

func partial(text string, t0, t1 float64) string {
	return fmt.Sprintf(`{"type":"partial","text":%q,"t0":%g,"t1":%g}`, text, t0, t1)
}

func final(text string, t0, t1 float64) string {
	return fmt.Sprintf(`{"type":"final","text":%q,"t0":%g,"t1":%g,"model":"moonshine-tiny","rtf":0.15}`, text, t0, t1)
}

// fakeServer speaks just enough of stt-remote/1: bearer/query auth before
// the upgrade (401 otherwise), then one script per accepted connection.
type fakeServer struct {
	token string
	ctx   context.Context // cancelled at test cleanup; bounds script writes
	url   string          // ws://127.0.0.1:PORT/v1/feed

	script func(ctx context.Context, conn *websocket.Conn, n int)

	mu    sync.Mutex
	conns []time.Time  // accept time per connection, index = n
	auths []authRecord // one per /v1/feed request
}

type authRecord struct {
	header string // Authorization header ("" if absent)
	query  string // ?token= value ("" if absent)
}

func newFake(t *testing.T, token string, script func(ctx context.Context, conn *websocket.Conn, n int)) *fakeServer {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	fs := &fakeServer{token: token, ctx: ctx, script: script}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/feed", func(w http.ResponseWriter, r *http.Request) {
		rec := authRecord{header: r.Header.Get("Authorization"), query: r.URL.Query().Get("token")}
		got := ""
		if strings.HasPrefix(rec.header, "Bearer ") {
			got = strings.TrimSpace(strings.TrimPrefix(rec.header, "Bearer "))
		}
		if got == "" {
			got = rec.query
		}
		fs.mu.Lock()
		fs.auths = append(fs.auths, rec)
		fs.mu.Unlock()
		if got != fs.token { // like sttd: 401 before the upgrade, no hints
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		fs.mu.Lock()
		fs.conns = append(fs.conns, time.Now())
		n := len(fs.conns) - 1
		fs.mu.Unlock()
		go fs.script(fs.ctx, conn, n)
	})
	srv := httptest.NewServer(mux)
	// LIFO cleanup: cancel unblocks held scripts before srv.Close waits.
	t.Cleanup(srv.Close)
	t.Cleanup(cancel)
	fs.url = "ws" + strings.TrimPrefix(srv.URL, "http") + "/v1/feed"
	return fs
}

func (fs *fakeServer) connTimes() []time.Time {
	fs.mu.Lock()
	defer fs.mu.Unlock()
	return append([]time.Time(nil), fs.conns...)
}

func (fs *fakeServer) lastAuth() authRecord {
	fs.mu.Lock()
	defer fs.mu.Unlock()
	if len(fs.auths) == 0 {
		return authRecord{}
	}
	return fs.auths[len(fs.auths)-1]
}

// send writes lines as one WS text message each (contract §9.3).
func send(ctx context.Context, conn *websocket.Conn, lines ...string) {
	for _, l := range lines {
		if err := conn.Write(ctx, websocket.MessageText, []byte(l)); err != nil {
			return
		}
	}
}

// hold keeps a scripted connection open until the peer closes or the test
// ends, then closes politely (scripts that outlive their scripted events).
func hold(ctx context.Context, conn *websocket.Conn) {
	_, _, _ = conn.Reader(ctx)
	_ = conn.Close(websocket.StatusNormalClosure, "")
}

// collector adapts a Handler into a buffered channel of events.
func collector() (sttclient.Handler, <-chan sttclient.Event) {
	ch := make(chan sttclient.Event, 64)
	return func(ev sttclient.Event) { ch <- ev }, ch
}

// recvTexts waits (≤ 10 s) for the expected event texts, in order.
func recvTexts(t *testing.T, ch <-chan sttclient.Event, want ...string) {
	t.Helper()
	var got []string
	deadline := time.After(10 * time.Second)
	for len(got) < len(want) {
		select {
		case ev := <-ch:
			got = append(got, ev.Text)
		case <-deadline:
			t.Fatalf("got events %q, still waiting for %q (10 s timeout)", got, want)
		}
	}
	if !strings.EqualFold(strings.Join(got, "\x00"), strings.Join(want, "\x00")) {
		t.Fatalf("surfaced %q, want %q", got, want)
	}
}

// assertIdle fails if any event is waiting on ch (a surfaced duplicate).
func assertIdle(t *testing.T, ch <-chan sttclient.Event) {
	t.Helper()
	select {
	case ev := <-ch:
		t.Fatalf("unexpected extra surfaced event: %+v", ev)
	default:
	}
}

// runAsync runs c in the background; the returned stop cancels ctx and
// waits (≤ 10 s) for Run to return, handing back its error.
func runAsync(t *testing.T, c *sttclient.Client, h sttclient.Handler) (stop func() error) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	errCh := make(chan error, 1)
	go func() { errCh <- c.Run(ctx, h) }()
	return func() error {
		cancel()
		select {
		case err := <-errCh:
			return err
		case <-time.After(10 * time.Second):
			t.Fatal("Run did not return after ctx cancellation")
			return nil
		}
	}
}

// syncBuffer is a mutex-guarded log sink (the client logs from its own
// goroutine; tests read it after events are received).
type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) printf(format string, args ...any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	fmt.Fprintf(&s.b, format+"\n", args...)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

func TestFinalFilter(t *testing.T) {
	fs := newFake(t, "secret-token", func(ctx context.Context, conn *websocket.Conn, n int) {
		send(ctx, conn,
			helloActive, startLine,
			partial("ever tried", 0.0, 1.0),
			final("ever tried ever failed", 0.0, 2.5),
			partial("no matter", 2.6, 3.1),
			final("no matter try again", 2.6, 4.0),
		)
		hold(ctx, conn)
	})

	// Default: only finals reach the consumer.
	c := sttclient.New(fs.url, fs.token)
	h, ch := collector()
	stop := runAsync(t, c, h)
	recvTexts(t, ch, "ever tried ever failed", "no matter try again")
	assertIdle(t, ch)
	if err := stop(); err != nil && !errors.Is(err, context.Canceled) {
		t.Fatalf("Run: %v", err)
	}
	if st := c.Stats(); st != (sttclient.Stats{Surfaced: 2}) {
		t.Fatalf("stats = %+v, want surfaced=2 only", st)
	}

	// WithPartials(true): partials too, in server order.
	cp := sttclient.New(fs.url, fs.token, sttclient.WithPartials(true), sttclient.WithQuiet(true))
	hp, chp := collector()
	stopp := runAsync(t, cp, hp)
	recvTexts(t, chp, "ever tried", "ever tried ever failed", "no matter", "no matter try again")
	assertIdle(t, chp)
	if err := stopp(); err != nil && !errors.Is(err, context.Canceled) {
		t.Fatalf("Run (partials): %v", err)
	}
	if st := cp.Stats(); st.Surfaced != 4 {
		t.Fatalf("stats = %+v, want surfaced=4", st)
	}
}

func TestDedupeAfterReconnect(t *testing.T) {
	fs := newFake(t, "secret-token", func(ctx context.Context, conn *websocket.Conn, n int) {
		switch n {
		case 0: // mid-session loss: one final delivered, conn dies
			send(ctx, conn, helloActive, startLine, final("ever tried ever failed", 0.0, 2.5))
			_ = conn.CloseNow()
		default: // reconnect: start replay, the same final again, new text
			send(ctx, conn, helloActive, startLine,
				final("ever tried ever failed", 0.0, 2.5), // duplicate
				final("no matter try again", 2.6, 4.0),
			)
			hold(ctx, conn)
		}
	})

	c := sttclient.New(fs.url, fs.token)
	h, ch := collector()
	stop := runAsync(t, c, h)
	recvTexts(t, ch, "ever tried ever failed", "no matter try again")
	assertIdle(t, ch) // the replayed duplicate is never surfaced
	if err := stop(); err != nil && !errors.Is(err, context.Canceled) {
		t.Fatalf("Run: %v", err)
	}
	st := c.Stats()
	if st.Surfaced != 2 || st.Reconnects != 1 {
		t.Fatalf("stats = %+v, want surfaced=2 reconnects=1", st)
	}
	if st.DuplicatesSuppressed != 1 {
		t.Fatalf("duplicates_suppressed = %d, want 1", st.DuplicatesSuppressed)
	}
}

func TestNoCrossSessionSuppression(t *testing.T) {
	// Two sessions (fresh sttd after a hard death, like the reconnect
	// demo) replay the SAME audio through the same engine and both emit a
	// byte-identical final. They are different sessions: both must surface.
	fs := newFake(t, "secret-token", func(ctx context.Context, conn *websocket.Conn, n int) {
		switch n {
		case 0: // session 1: one final, then eof + close 1000 (§9.3)
			send(ctx, conn, helloWith("20261024-1"), startLine,
				final("ever tried ever failed", 0.0, 2.5),
				eofLine)
			_ = conn.Close(websocket.StatusNormalClosure, "session ended")
		case 1: // session 2: the identical final, legitimately re-produced
			send(ctx, conn, helloWith("20261024-2"), startLine,
				final("ever tried ever failed", 0.0, 2.5),
				eofLine)
			_ = conn.Close(websocket.StatusNormalClosure, "session ended")
		default:
			hold(ctx, conn) // no session 3; keep the feed open
		}
	})

	c := sttclient.New(fs.url, fs.token)
	h, ch := collector()
	stop := runAsync(t, c, h)
	recvTexts(t, ch, "ever tried ever failed", "ever tried ever failed")
	assertIdle(t, ch) // nothing beyond the two identical finals
	if err := stop(); err != nil && !errors.Is(err, context.Canceled) {
		t.Fatalf("Run: %v", err)
	}
	st := c.Stats()
	if st.Surfaced != 2 || st.Reconnects < 1 {
		t.Fatalf("stats = %+v, want surfaced=2 reconnects≥1", st)
	}
	if st.DuplicatesSuppressed != 0 {
		t.Fatalf("duplicates_suppressed = %d, want 0: cross-session events are not duplicates", st.DuplicatesSuppressed)
	}
}

func TestReconnectBackoff(t *testing.T) {
	fs := newFake(t, "secret-token", func(ctx context.Context, conn *websocket.Conn, n int) {
		if n < 2 {
			_ = conn.CloseNow() // drop the first two connections
			return
		}
		send(ctx, conn, helloActive, startLine, final("third time lucky", 0.0, 1.0))
		hold(ctx, conn)
	})

	// Seeded jitter source (injectable): delays are reproducible, but the
	// assertions stay wide bounds so they cannot flake.
	c := sttclient.New(fs.url, fs.token, sttclient.WithRand(rand.New(rand.NewSource(7))))
	h, ch := collector()
	stop := runAsync(t, c, h)
	recvTexts(t, ch, "third time lucky") // events from the 3rd connection
	if err := stop(); err != nil && !errors.Is(err, context.Canceled) {
		t.Fatalf("Run: %v", err)
	}

	times := fs.connTimes()
	if len(times) != 3 {
		t.Fatalf("server saw %d connections, want 3", len(times))
	}
	d1, d2 := times[1].Sub(times[0]), times[2].Sub(times[1])
	// Ladder 250 ms → 500 ms with ±20% jitter: assert generous bounds
	// ([200 ms, 1.5 s] and [400 ms, 2 s], never flake in practice).
	if d1 < 200*time.Millisecond || d1 > 1500*time.Millisecond {
		t.Errorf("first retry delay = %v, want within [200ms, 1.5s]", d1)
	}
	if d2 < 400*time.Millisecond || d2 > 2000*time.Millisecond {
		t.Errorf("second retry delay = %v, want within [400ms, 2s]", d2)
	}
	if total := times[2].Sub(times[0]); total > 5*time.Second {
		t.Errorf("two retries took %v, want ≤ 5s in total", total)
	}
	if st := c.Stats(); st.Reconnects != 2 || st.Surfaced != 1 {
		t.Fatalf("stats = %+v, want reconnects=2 surfaced=1", st)
	}
}

func TestLazyAttach(t *testing.T) {
	fs := newFake(t, "secret-token", func(ctx context.Context, conn *websocket.Conn, n int) {
		// Idle server at hello, then capture starts on the same connection.
		send(ctx, conn, helloIdle, startLine,
			partial("ever tried", 0.0, 1.0),
			final("ever tried ever failed", 0.0, 2.5),
		)
		hold(ctx, conn)
	})

	logs := &syncBuffer{}
	c := sttclient.New(fs.url, fs.token,
		sttclient.WithPartials(true),
		sttclient.WithLogger(logs.printf),
	)
	h, ch := collector()
	stop := runAsync(t, c, h)
	// hello (session:null) → start → partial → final: order preserved.
	recvTexts(t, ch, "ever tried", "ever tried ever failed")
	assertIdle(t, ch)
	if err := stop(); err != nil && !errors.Is(err, context.Canceled) {
		t.Fatalf("Run: %v", err)
	}
	if msg := logs.String(); !strings.Contains(msg, "waiting") {
		t.Errorf("hello with session:null should log a waiting info line, got:\n%s", msg)
	}
}

func TestAuthHeaderAndQuery(t *testing.T) {
	fs := newFake(t, "secret-token", func(ctx context.Context, conn *websocket.Conn, n int) {
		send(ctx, conn, helloActive, startLine, final("hello auth", 0.0, 1.0))
		hold(ctx, conn)
	})

	t.Run("bearer header", func(t *testing.T) {
		c := sttclient.New(fs.url, fs.token)
		h, ch := collector()
		stop := runAsync(t, c, h)
		recvTexts(t, ch, "hello auth")
		_ = stop()
		rec := fs.lastAuth()
		if rec.header != "Bearer secret-token" {
			t.Errorf("Authorization = %q, want %q", rec.header, "Bearer secret-token")
		}
		if rec.query != "" {
			t.Errorf("unexpected ?token= in query: %q", rec.query)
		}
	})

	t.Run("query token fallback", func(t *testing.T) {
		c := sttclient.New(fs.url, fs.token, sttclient.WithQueryToken(true))
		h, ch := collector()
		stop := runAsync(t, c, h)
		recvTexts(t, ch, "hello auth")
		_ = stop()
		rec := fs.lastAuth()
		if rec.header != "" {
			t.Errorf("unexpected Authorization header: %q", rec.header)
		}
		if rec.query != "secret-token" {
			t.Errorf("?token= = %q, want %q", rec.query, "secret-token")
		}
	})

	t.Run("rejected token fails fast", func(t *testing.T) {
		c := sttclient.New(fs.url, "wrong-token")
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		err := c.Run(ctx, func(sttclient.Event) {})
		var ae *sttclient.AuthError
		if !errors.As(err, &ae) {
			t.Fatalf("Run error = %v, want *AuthError (no retry loop on 401)", err)
		}
	})
}

func TestCleanShutdown(t *testing.T) {
	fs := newFake(t, "secret-token", func(ctx context.Context, conn *websocket.Conn, n int) {
		send(ctx, conn, helloActive, startLine, final("ever tried ever failed", 0.0, 2.5))
		hold(ctx, conn)
	})

	c := sttclient.New(fs.url, fs.token)
	h, ch := collector()
	ctx, cancel := context.WithCancel(context.Background())
	errCh := make(chan error, 1)
	go func() { errCh <- c.Run(ctx, h) }()
	recvTexts(t, ch, "ever tried ever failed")

	start := time.Now()
	cancel()
	select {
	case err := <-errCh:
		if elapsed := time.Since(start); elapsed > 2*time.Second {
			t.Fatalf("Run took %v to return after cancel, want < 2s", elapsed)
		}
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("Run error = %v, want context.Canceled", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not return after ctx cancellation")
	}
	st := c.Stats()
	if st != (sttclient.Stats{Surfaced: 1}) {
		t.Fatalf("summary counts = %+v, want surfaced=1 only", st)
	}
}

func TestOnceEofExits(t *testing.T) {
	fs := newFake(t, "secret-token", func(ctx context.Context, conn *websocket.Conn, n int) {
		send(ctx, conn, helloActive, startLine,
			final("beckett", 0.0, 9.9),
			`{"type":"eof","frames":1,"audio_s":9.96,"rss_kb":262968}`,
		)
		// Server closes 1000 after eof (contract §9.3); a --once client
		// has already exited instead of reconnecting.
		_ = conn.Close(websocket.StatusNormalClosure, "eof")
	})

	c := sttclient.New(fs.url, fs.token, sttclient.WithOnce(true))
	h, ch := collector()
	errCh := make(chan error, 1)
	go func() { errCh <- c.Run(context.Background(), h) }()
	recvTexts(t, ch, "beckett")
	select {
	case err := <-errCh:
		if err != nil {
			t.Fatalf("Run = %v, want nil after eof with --once", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Run did not return after eof with --once")
	}
	if st := c.Stats(); st != (sttclient.Stats{Surfaced: 1}) {
		t.Fatalf("stats = %+v, want surfaced=1, no reconnects", st)
	}
}
