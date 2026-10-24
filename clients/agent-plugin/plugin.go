// Package sttclient is the reference stt-remote/1 client (Spec C, S6.5),
// the pattern agent plugins should embed to consume an sttd feed
// (docs/CONTRATOS.md §9).
//
// It speaks the contract as specified: token-authenticated handshake
// (Authorization header, or ?token= for clients that cannot set headers),
// hello with the session descriptor, lazy attach when "session":null, and
// live stt-events/1 lines, one per WS text message, verbatim. v1 has no
// history (docs/OPERACION.md §7.3): on every (re)connect the server
// replays start and only later text follows, so the client reconnects with
// exponential backoff and never assumes it recovers text missed while
// disconnected. A bounded dedupe ring scoped to ONE session still
// guarantees that the consumer never sees the same event twice within
// that session, whatever the transport redelivers; a new session (a start
// after a hello naming a different session id) resets the ring, so the
// same audio recognized again in another session surfaces again.
//
// Embedding takes ~20 lines:
//
//	c := sttclient.New("ws://127.0.0.1:4719/v1/feed", token)
//	err := c.Run(ctx, func(ev sttclient.Event) { fmt.Println(ev.Raw) })
package sttclient

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand"
	"net/http"
	"net/url"
	"os"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// Protocol identifies the remote contract this client speaks.
const Protocol = "stt-remote/1"

// Contract-tuned constants (Spec C §1.1; docs/CONTRATOS.md §9).
const (
	// closeGrace bounds the polite close handshake before CloseNow: Run
	// must return promptly when ctx is cancelled.
	closeGrace = 500 * time.Millisecond
	// dedupeCap is the size of the dedupe ring: the last dedupeCap
	// surfaced events are remembered (bounded memory).
	dedupeCap = 64
	// backoffJitter is the ± fraction randomized onto each backoff step.
	backoffJitter = 0.2
)

// backoffSteps is the reconnect ladder: 250 ms → 500 ms → 1 s → 2 s → 5 s
// (cap), per Spec C §1.1.
var backoffSteps = [...]time.Duration{
	250 * time.Millisecond,
	500 * time.Millisecond,
	1 * time.Second,
	2 * time.Second,
	5 * time.Second,
}

// errEOS makes Run return cleanly when an eof arrives with WithOnce(true).
var errEOS = errors.New("end of stream (eof)")

// Event is one stt-events/1 line. Raw is the original NDJSON line
// verbatim, so consumers can log or forward it without re-marshalling.
type Event struct {
	Type string  // "partial", "final", ... (stt-events/1 type)
	Text string  // recognized text (partial/final events)
	T0   float64 // segment start, seconds into the session
	T1   float64 // segment end, seconds into the session
	Raw  string  // original NDJSON line, as sent by sttd
}

// Handler receives surfaced events, in server order, on Run's goroutine.
// Run does not read the feed while Handler runs: keep it quick, or hand
// events off to your own queue.
type Handler func(ev Event)

// Stats is the run summary; the CLI prints it as one stderr line on
// shutdown.
type Stats struct {
	Surfaced             int64 // events passed to the Handler
	DuplicatesSuppressed int64 // same-session repeats dropped by the ring
	Reconnects           int64 // reconnections performed
}

// AuthError reports HTTP 401 at the WebSocket handshake: the token is
// missing or wrong (contract §9.2). Retrying cannot help, so Run fails
// fast instead of backing off; the CLI maps it to exit code 2.
type AuthError struct {
	URL string
}

func (e *AuthError) Error() string {
	return fmt.Sprintf("stt-client: %s rejected the token (HTTP 401); check the token", e.URL)
}

// Client is a reusable stt-remote/1 feed consumer. Build it with New and
// run it with Run; it is safe to read Stats from another goroutine while
// Run works.
type Client struct {
	url        string
	token      string
	partials   bool // surface partial events too (default: finals only)
	once       bool // return after the first eof instead of reconnecting
	queryToken bool // send ?token= instead of the Authorization header
	quiet      bool // drop info diagnostics (errors are always printed)

	logf func(format string, args ...any) // info diagnostics sink
	rand *rand.Rand                       // backoff jitter source

	mu         sync.Mutex
	stats      Stats
	dedupe     []dedupeKey // ring of the last dedupeCap surfaced keys
	dedupeNext int         // ring write cursor, used once len == dedupeCap
	ringSess   string      // session id the dedupe ring belongs to
	helloSess  string      // session id from the latest hello ("" when null)
	helloSeen  bool        // descriptor logged once per Run
}

// dedupeKey identifies an event for the at-most-once guarantee:
// (type, t0, t1, text) of a surfaced event.
type dedupeKey struct {
	typ  string
	t0   float64
	t1   float64
	text string
}

// Option configures a Client (see the With* constructors).
type Option func(*Client)

// WithPartials also surfaces partial events; by default only final
// events reach the Handler.
func WithPartials(yes bool) Option { return func(c *Client) { c.partials = yes } }

// WithOnce makes Run return cleanly after the first eof event instead of
// reconnecting to wait for the next session.
func WithOnce(yes bool) Option { return func(c *Client) { c.once = yes } }

// WithQueryToken sends the token as ?token= instead of the Authorization
// header, demonstrating the browser fallback path (contract §9.2).
func WithQueryToken(yes bool) Option { return func(c *Client) { c.queryToken = yes } }

// WithQuiet suppresses info diagnostics (hello descriptor, session
// lifecycle); errors are still printed to stderr.
func WithQuiet(yes bool) Option { return func(c *Client) { c.quiet = yes } }

// WithLogger replaces the info diagnostics sink (fmt.Printf style,
// newline appended). The default writes "stt-agent-plugin: ..." on stderr.
func WithLogger(f func(format string, args ...any)) Option {
	return func(c *Client) {
		if f != nil {
			c.logf = f
		}
	}
}

// WithRand sets the jitter source of the reconnect backoff (seed it for
// reproducible delays). The default is a time-seeded source.
func WithRand(r *rand.Rand) Option {
	return func(c *Client) {
		if r != nil {
			c.rand = r
		}
	}
}

// New builds a Client for the feed url ("ws://host:port/v1/feed"),
// authenticated with token. Apply Options to change what is surfaced.
func New(url, token string, opts ...Option) *Client {
	c := &Client{url: url, token: token}
	c.logf = func(format string, args ...any) {
		fmt.Fprintf(os.Stderr, "stt-agent-plugin: "+format+"\n", args...)
	}
	c.rand = rand.New(rand.NewSource(time.Now().UnixNano()))
	for _, opt := range opts {
		opt(c)
	}
	if c.quiet {
		c.logf = func(string, ...any) {}
	}
	return c
}

// Stats returns the run summary so far (surfaced events, duplicates
// suppressed, reconnects).
func (c *Client) Stats() Stats {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.stats
}

// Run connects to the feed and calls h for every surfaced event — final
// events by default, partials too with WithPartials — until ctx is
// cancelled (returns ctx.Err()), an eof arrives with WithOnce(true)
// (returns nil), or the handshake is rejected with HTTP 401 (returns
// *AuthError). Any other connection loss — including the server's close
// 1000 after eof, 1001, 1011 and 1013 — reconnects with exponential
// backoff; after a reconnect the server replays start and only new text
// follows, and anything redelivered within the same session is suppressed
// by the per-session dedupe ring (a new session resets it).
func (c *Client) Run(ctx context.Context, h Handler) error {
	c.mu.Lock()
	c.helloSeen = false
	c.mu.Unlock()
	for attempt := 0; ; {
		err := c.runConn(ctx, h)
		if errors.Is(err, errEOS) { // eof with WithOnce(true)
			return nil
		}
		if ctx.Err() != nil { // cancelled (SIGINT/SIGTERM upstream): clean stop
			return ctx.Err()
		}
		var ae *AuthError
		if errors.As(err, &ae) {
			return err // a bad token will not fix itself; fail fast
		}
		attempt++
		delay := c.backoff(attempt)
		c.warnf("connection lost (%v); reconnect %d in %s", err, attempt, delay)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
		c.mu.Lock()
		c.stats.Reconnects++
		c.mu.Unlock()
	}
}

// runConn lives one connection: dial, then read one stt-events/1 line per
// WS text message until the connection is lost, the stream ends or ctx is
// cancelled.
//
// Reads run on their own goroutine with a context deliberately NOT derived
// from ctx: cancelling a pending Read tears the connection down without a
// close frame (library rule), and a clean SIGINT/SIGTERM shutdown wants the
// polite close handshake first. shutdown below bounds both.
func (c *Client) runConn(ctx context.Context, h Handler) error {
	conn, err := c.dial(ctx)
	if err != nil {
		return err
	}
	readCtx, cancelRead := context.WithCancel(context.Background())
	msgs := make(chan []byte, 1)
	readErr := make(chan error, 1)
	go func() {
		for {
			_, data, err := conn.Read(readCtx)
			if err != nil {
				readErr <- err
				return
			}
			select {
			case msgs <- data:
			case <-readCtx.Done():
				return
			}
		}
	}()
	defer c.shutdown(conn, cancelRead)
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err := <-readErr:
			return fmt.Errorf("read: %w", err)
		case data := <-msgs:
			if err := c.handle(h, data); err != nil {
				return err
			}
		}
	}
}

// shutdown closes the WebSocket politely (close frame, then the peer's
// echo, handled by the pending read) but never blocks Run for more than
// closeGrace: a peer stalling the handshake is aborted by cancelling the
// read context, and the background Close drains within the library's own
// internal timeouts. Either way Run keeps its prompt-shutdown guarantee.
func (c *Client) shutdown(conn *websocket.Conn, cancelRead context.CancelFunc) {
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = conn.Close(websocket.StatusNormalClosure, "client shutdown")
	}()
	select {
	case <-done:
	case <-time.After(closeGrace):
		cancelRead() // stuck handshake: abort, let Close drain in background
	}
	cancelRead() // release a reader straggler blocked on sending
}

// dial performs the token-authenticated handshake (contract §9.2): the
// Authorization header by default, ?token= with WithQueryToken. The token
// never appears in error text.
func (c *Client) dial(ctx context.Context) (*websocket.Conn, error) {
	target := c.url
	if c.queryToken {
		u, err := url.Parse(c.url)
		if err != nil {
			return nil, fmt.Errorf("bad url %q: %w", c.url, err)
		}
		q := u.Query()
		q.Set("token", c.token)
		u.RawQuery = q.Encode()
		target = u.String()
	}
	opts := &websocket.DialOptions{HTTPHeader: http.Header{}}
	if !c.queryToken {
		opts.HTTPHeader.Set("Authorization", "Bearer "+c.token)
	}
	conn, resp, err := websocket.Dial(ctx, target, opts)
	if err != nil {
		if resp != nil && resp.StatusCode == http.StatusUnauthorized {
			return nil, &AuthError{URL: c.url}
		}
		if resp != nil {
			return nil, fmt.Errorf("dial %s: HTTP %d: %w", c.url, resp.StatusCode, err)
		}
		return nil, fmt.Errorf("dial %s: %w", c.url, err)
	}
	return conn, nil
}

// handle applies one WS text message (exactly one stt-events/1 line,
// contract §9.3): lifecycle events are logged, text events are filtered,
// deduplicated and surfaced.
func (c *Client) handle(h Handler, data []byte) error {
	line := string(data)
	var raw struct {
		Type string  `json:"type"`
		Text string  `json:"text"`
		T0   float64 `json:"t0"`
		T1   float64 `json:"t1"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		c.warnf("ignoring malformed event: %v: %s", err, line)
		return nil // a bad line never kills the feed
	}
	switch raw.Type {
	case "hello":
		c.onHello(data)
	case "start":
		c.onSessionStart()
		c.logf("session started: %s", line)
	case "eof":
		c.logf("session ended (eof)")
		if c.once {
			return errEOS
		}
	case "error":
		c.warnf("server error event: %s", line)
	case "partial":
		if c.partials {
			c.surface(h, Event{Type: raw.Type, Text: raw.Text, T0: raw.T0, T1: raw.T1, Raw: line})
		}
	case "final":
		c.surface(h, Event{Type: raw.Type, Text: raw.Text, T0: raw.T0, T1: raw.T1, Raw: line})
	default:
		c.logf("ignoring unknown event: %s", line)
	}
	return nil
}

// onHello logs the session descriptor once per Run (contract §9.3): an
// active session carries id/engine/partials/start time; session:null means
// lazy attach — stay connected and start arrives when capture begins
// (docs/OPERACION.md §7.3). Hellos after a reconnect log a short line.
func (c *Client) onHello(data []byte) {
	var msg struct {
		Protocol string `json:"protocol"`
		Server   string `json:"server"`
		Session  *struct {
			ID        string          `json:"id"`
			Engine    string          `json:"engine"`
			Partials  bool            `json:"partials"`
			StartedAt string          `json:"started_at"`
			Audio     json.RawMessage `json:"audio"`
		} `json:"session"`
	}
	if err := json.Unmarshal(data, &msg); err != nil {
		c.warnf("malformed hello: %v", err)
		return
	}
	c.mu.Lock()
	first := !c.helloSeen
	c.helloSeen = true
	c.helloSess = "" // session:null until a session is named below
	if msg.Session != nil {
		c.helloSess = msg.Session.ID
	}
	c.mu.Unlock()
	if msg.Session == nil {
		if first {
			c.logf("connected (%s, %s): no active session, waiting for one (lazy attach)",
				msg.Server, msg.Protocol)
		} else {
			c.logf("reconnected: no active session, waiting for one (lazy attach)")
		}
		return
	}
	desc := fmt.Sprintf("session %s (engine %s, partials=%v, started %s)",
		msg.Session.ID, msg.Session.Engine, msg.Session.Partials, msg.Session.StartedAt)
	if first {
		c.logf("connected (%s, %s): %s", msg.Server, msg.Protocol, desc)
	} else {
		c.logf("reconnected: %s", desc)
	}
}

// onSessionStart applies the per-session dedupe rule at every start: the
// ring exists to suppress replay WITHIN one session (the start re-sent
// after a mid-session reconnect, client-side double processing), so it is
// cleared whenever a NEW session begins — a start that follows a hello
// whose session id differs from the one the ring belongs to. After eof the
// server closes the connection (contract §9.3), so a new session always
// announces itself in a fresh hello (a different id, or null on lazy
// attach); a reconnect landing in the same session keeps the ring, and a
// session legitimately re-producing an identical event surfaces it again.
func (c *Client) onSessionStart() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.helloSess == c.ringSess {
		return // same session (or the very first start): keep the ring
	}
	c.dedupe = c.dedupe[:0]
	c.dedupeNext = 0
	c.ringSess = c.helloSess
}

// surface hands ev to h unless it repeats one of the last dedupeCap
// surfaced events of the SAME session (same type, t0, t1 and text). The
// server replays only start in v1, but the client side of the contract is
// at-most-once delivery per session: repeats are counted, never surfaced.
func (c *Client) surface(h Handler, ev Event) {
	c.mu.Lock()
	key := dedupeKey{typ: ev.Type, t0: ev.T0, t1: ev.T1, text: ev.Text}
	for _, k := range c.dedupe {
		if k == key {
			c.stats.DuplicatesSuppressed++
			c.mu.Unlock()
			return
		}
	}
	if len(c.dedupe) < dedupeCap {
		c.dedupe = append(c.dedupe, key)
	} else {
		c.dedupe[c.dedupeNext] = key
		c.dedupeNext = (c.dedupeNext + 1) % dedupeCap
	}
	c.stats.Surfaced++
	c.mu.Unlock()
	h(ev)
}

// backoff returns the reconnect delay after the n-th consecutive loss
// (n ≥ 1): the ladder 250 ms → 500 ms → 1 s → 2 s → 5 s cap, each step
// randomized by ±backoffJitter.
func (c *Client) backoff(n int) time.Duration {
	if n < 1 {
		n = 1
	}
	i := n - 1
	if i >= len(backoffSteps) {
		i = len(backoffSteps) - 1
	}
	c.mu.Lock()
	factor := 1 + (c.rand.Float64()-0.5)*2*backoffJitter
	c.mu.Unlock()
	return time.Duration(float64(backoffSteps[i]) * factor)
}

// warnf prints diagnostics that --quiet cannot suppress (errors, losses).
func (c *Client) warnf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "stt-agent-plugin: "+format+"\n", args...)
}
