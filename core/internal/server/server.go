// Package server implements the stt-remote/1 delivery service (sttd): a
// WebSocket hub that republishes the stt-events/1 NDJSON stdout of one
// supervised session pipeline, verbatim, to N receive-only clients
// (docs/CONTRATOS.md §9; docs/ARQUITECTURA.md §3.2, decisions D15–D19).
//
// The hub never interprets or rewrites events (invariant I5): every pipeline
// line becomes exactly one WS text message. A slow or unresponsive client is
// dropped alone (invariant I7). The nucleus, adapters and contracts are not
// touched (invariants I2/I3).
package server

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
)

const (
	// ProtocolVersion is the remote protocol served (contract §9).
	ProtocolVersion = "stt-remote/1"
	// ServerVersion identifies sttd in the hello message.
	ServerVersion = "sttd/0.1"
)

// Contract defaults (docs/CONTRATOS.md §9.3–9.4).
const (
	defaultListen       = "127.0.0.1:4719" // loopback only; LAN is opt-in (D18)
	defaultMaxClients   = 8
	defaultQueueLen     = 256
	defaultPingInterval = 20 * time.Second
	defaultPongTimeout  = 60 * time.Second
	defaultDrainTimeout = 2 * time.Second
	defaultMaxRestarts  = 3
	defaultRestartWin   = 60 * time.Second
	defaultRestartDelay = 2 * time.Second
	killDelay           = 5 * time.Second // stop signal before hard kill
)

// defaultAudio is the audio object hello advertises when a start event did
// not carry one (CONTRATOS §1: PCM s16le 16 kHz mono).
var defaultAudio = json.RawMessage(`{"rate":16000,"channels":1,"format":"s16le"}`)

// Options configures a Hub. Zero fields fall back to the contract defaults.
type Options struct {
	Listen       string
	Token        string // resolved bearer token (required; see LoadToken)
	MaxClients   int
	QueueLen     int // per-client event queue; full queue drops that client
	PingInterval time.Duration
	PongTimeout  time.Duration // no pong within this window closes the client
	DrainTimeout time.Duration // bounded drain before closing after eof
	Engine       string        // hello.session.engine descriptor
	Partials     bool          // hello.session.partials descriptor

	// OnClientClose, when set, is called once per client with the close code
	// the server used. Test observability for slow/unresponsive drops.
	OnClientClose func(code websocket.StatusCode, reason string)
}

// session is the active pipeline session: idle → running → eof → idle.
type session struct {
	id        string
	startedAt time.Time
	startLine []byte          // raw start event, replayed to late clients
	audio     json.RawMessage // audio object of the replayed start event
}

// Hub is the stt-remote/1 server: HTTP health endpoint plus the /v1/feed
// WebSocket fan-out. Events enter through Publish (the pipeline stdout) and
// are broadcast verbatim to every connected client.
type Hub struct {
	ln   net.Listener
	srv  *http.Server
	opts Options

	mu      sync.Mutex
	clients map[*client]struct{}
	sess    *session
	closed  bool

	wg sync.WaitGroup
}

// New binds the listener and returns an idle hub. Call Serve to accept.
func New(opts Options) (*Hub, error) {
	if opts.Token == "" {
		return nil, fmt.Errorf("server: empty bearer token; refusing to serve unauthenticated")
	}
	if opts.Listen == "" {
		opts.Listen = defaultListen
	}
	if opts.MaxClients <= 0 {
		opts.MaxClients = defaultMaxClients
	}
	if opts.QueueLen <= 0 {
		opts.QueueLen = defaultQueueLen
	}
	if opts.PingInterval <= 0 {
		opts.PingInterval = defaultPingInterval
	}
	if opts.PongTimeout <= 0 {
		opts.PongTimeout = defaultPongTimeout
	}
	if opts.DrainTimeout <= 0 {
		opts.DrainTimeout = defaultDrainTimeout
	}
	ln, err := net.Listen("tcp", opts.Listen)
	if err != nil {
		return nil, fmt.Errorf("server: listen %s: %w", opts.Listen, err)
	}
	h := &Hub{
		ln:      ln,
		opts:    opts,
		clients: make(map[*client]struct{}),
	}
	h.srv = &http.Server{Handler: h}
	return h, nil
}

// Addr returns the bound address (tests use "127.0.0.1:0").
func (h *Hub) Addr() string { return h.ln.Addr().String() }

// Serve runs the accept loop in the background.
func (h *Hub) Serve() {
	h.wg.Add(1)
	go func() {
		defer h.wg.Done()
		if err := h.srv.Serve(h.ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			debugf("serve loop: %v", err)
		}
	}()
}

// ServeHTTP routes /healthz and /v1/feed; anything else is 404.
func (h *Hub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Never log r.URL: the token travels in the query string fallback.
	switch r.URL.Path {
	case "/healthz":
		h.handleHealthz(w)
	case "/v1/feed":
		h.handleFeed(w, r)
	default:
		http.NotFound(w, r)
	}
}

type healthzResponse struct {
	Status   string `json:"status"`
	Protocol string `json:"protocol"`
	Session  bool   `json:"session"`
}

func (h *Hub) handleHealthz(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(healthzResponse{
		Status:   "ok",
		Protocol: ProtocolVersion,
		Session:  h.SessionActive(),
	})
}

// authorized checks the bearer token before any upgrade (contract §9.2):
// Authorization header first, ?token= fallback for clients that cannot set
// headers (browsers). Missing or wrong token: 401, no hint about anything.
func (h *Hub) authorized(r *http.Request) bool {
	got := ""
	if auth := r.Header.Get("Authorization"); strings.HasPrefix(auth, "Bearer ") {
		got = strings.TrimSpace(strings.TrimPrefix(auth, "Bearer "))
	} else if q := r.URL.Query().Get("token"); q != "" {
		got = q
	}
	return tokenEqual(got, h.opts.Token)
}

func (h *Hub) handleFeed(w http.ResponseWriter, r *http.Request) {
	if !h.authorized(r) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte("unauthorized\n"))
		return
	}
	// Reserve a client slot before the upgrade so max_clients is enforced
	// with a plain HTTP 503 (contract §9.4).
	c, hello, replay := h.reserve()
	if c == nil {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte("too many clients\n"))
		return
	}
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// Receive-only feed authenticated by token: browsers on any origin
		// may subscribe (they cannot set the Authorization header).
		OriginPatterns: []string{"*"},
	})
	if err != nil {
		debugf("upgrade failed: %v", err)
		h.removeClient(c)
		return
	}
	if !h.activate(c) {
		_ = conn.CloseNow()
		return
	}
	debugf("client connected (total %d)", h.Clients())
	c.start(h, conn, hello, replay)
}

// reserve registers a client slot and snapshots the hello payload (session
// state at connect time) under one lock.
func (h *Hub) reserve() (*client, []byte, []byte) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed || len(h.clients) >= h.opts.MaxClients {
		return nil, nil, nil
	}
	c := &client{
		ch:         make(chan []byte, h.opts.QueueLen),
		done:       make(chan struct{}),
		writerDone: make(chan struct{}),
	}
	h.clients[c] = struct{}{}
	var sess *helloSession
	var replay []byte
	if h.sess != nil {
		replay = h.sess.startLine
		sess = &helloSession{
			ID:        h.sess.id,
			Engine:    h.opts.Engine,
			Partials:  h.opts.Partials,
			StartedAt: h.sess.startedAt.Format(time.RFC3339),
			Audio:     h.sess.audio,
		}
	}
	hello, err := json.Marshal(helloMessage{
		Type: "hello", Protocol: ProtocolVersion, Server: ServerVersion, Session: sess,
	})
	if err != nil { // unreachable: all fields are trivially marshalable
		delete(h.clients, c)
		return nil, nil, nil
	}
	return c, hello, replay
}

// activate arms the client goroutine counter after a successful upgrade.
// wg.Add happens under the hub lock so Close (which sets closed under the
// same lock) can never race an Add with its Wait.
func (h *Hub) activate(c *client) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		delete(h.clients, c)
		return false
	}
	h.wg.Add(3)
	return true
}

// helloMessage is the first WS message after the upgrade (contract §9.3).
type helloMessage struct {
	Type     string        `json:"type"`
	Protocol string        `json:"protocol"`
	Server   string        `json:"server"`
	Session  *helloSession `json:"session"` // null = idle (lazy attach)
}

type helloSession struct {
	ID        string          `json:"id"`
	Engine    string          `json:"engine"`
	Partials  bool            `json:"partials"`
	StartedAt string          `json:"started_at"`
	Audio     json.RawMessage `json:"audio"`
}

// client is one connected receive-only consumer.
type client struct {
	conn        *websocket.Conn
	hub         *Hub
	ch          chan []byte
	done        chan struct{} // closed once the terminal close has been decided
	writerDone  chan struct{}
	writeCtx    context.Context    // bounds data writes; cancelled only to force-abort a stuck writer
	writeCancel context.CancelFunc // (a cancelled in-flight Write tears the conn down: last resort)
	once        sync.Once
	closeCode   websocket.StatusCode // terminal close decision, performed by the writer
	closeReason string

	enqueued atomic.Int64 // events enqueued by broadcast (counted before send)
	sent     atomic.Int64 // events fully written to the connection
}

func (c *client) start(h *Hub, conn *websocket.Conn, hello, replay []byte) {
	c.hub = h
	c.conn = conn
	c.writeCtx, c.writeCancel = context.WithCancel(context.Background())
	go func() {
		defer h.wg.Done()
		c.writeLoop(hello, replay)
	}()
	go func() {
		defer h.wg.Done()
		c.readLoop()
	}()
	go func() {
		defer h.wg.Done()
		c.pingLoop()
	}()
}

// beginClose decides the terminal close exactly once: the observer hook
// fires (before the connection state changes, so a watcher that saw the
// client leave the hub always sees the close code too), the loops are
// woken and, when force is set, a writer stuck on a full TCP window is
// aborted. The close handshake itself is left to the writer goroutine
// (finish); it must NOT happen here: cancelling the write context (or
// otherwise closing the connection) while conn.Close is in flight would
// tear the connection down without a close frame and the peer would see a
// bare EOF instead of the status code.
func (c *client) beginClose(code websocket.StatusCode, reason string, force bool) {
	c.once.Do(func() {
		c.decideClose(code, reason, force)
	})
}

// decideClose is the once-only decision body (callers serialize it through
// c.once; it must never touch c.once itself).
func (c *client) decideClose(code websocket.StatusCode, reason string, force bool) {
	c.closeCode, c.closeReason = code, reason
	if c.hub != nil {
		if hook := c.hub.opts.OnClientClose; hook != nil {
			hook(code, reason)
		}
	}
	close(c.done)
	if force && c.writeCancel != nil {
		c.writeCancel()
	}
}

// writeLoop sends hello, the replayed start (if the session was already
// active) and then every live event, in order, one text message per event.
// It is the only goroutine that writes, so it also owns the terminal close
// sequence (finish): by the time finish runs, no data write is in flight
// and the close frame can never race a force-close.
func (c *client) writeLoop(hello, replay []byte) {
	// Defers run last-registered-first: leave the hub, announce the writer
	// done, then perform the terminal close handshake.
	defer c.finish()
	defer close(c.writerDone)
	defer c.hub.removeClient(c)

	if err := c.write(hello); err != nil {
		debugf("hello write failed: %v", err)
		c.beginClose(websocket.StatusTryAgainLater, "unreachable", true)
		return
	}
	if replay != nil {
		if err := c.write(replay); err != nil {
			debugf("start replay write failed: %v", err)
			c.beginClose(websocket.StatusTryAgainLater, "unreachable", true)
			return
		}
	}
	for {
		select {
		case b := <-c.ch:
			if err := c.write(b); err != nil {
				debugf("event write failed: %v", err)
				c.beginClose(websocket.StatusTryAgainLater, "unreachable", true)
				return
			}
			c.sent.Add(1)
		case <-c.done:
			return
		}
	}
}

// finish performs the terminal close: a proper close handshake with the
// status code decided by beginClose (the library bounds the handshake at
// 5 s per direction and relies on the never-cancelled read loop to receive
// the peer's echo), then CloseNow as a last resort. Exactly one goroutine
// — the writer — calls this, so the peer always observes the close frame
// unless the connection is already dead.
func (c *client) finish() {
	err := c.conn.Close(c.closeCode, c.closeReason)
	_ = c.conn.CloseNow()
	if c.writeCancel != nil {
		c.writeCancel() // no-op unless a straggler write is somehow blocked
	}
	debugf("client finished: close(%d): %v", c.closeCode, err)
}

func (c *client) write(b []byte) error {
	// No extra deadline: a stuck write is aborted when the client is
	// dropped (queue overflow, ping timeout) and writeCtx is cancelled.
	return c.conn.Write(c.writeCtx, websocket.MessageText, b)
}

// readLoop ignores client data messages (receive-only, contract §9.3) while
// processing the control frames: this is where pongs and close echoes reach
// the library. Its context is deliberately never cancelled: cancelling a
// pending Reader tears the whole connection down without a close frame
// (which the peer sees as an abrupt EOF). The loop ends when the terminal
// close in finish (or the peer) closes the connection.
func (c *client) readLoop() {
	for {
		_, r, err := c.conn.Reader(context.Background())
		if err != nil {
			debugf("client read ended: %v", err)
			c.beginClose(websocket.StatusNormalClosure, "client went away", true)
			return
		}
		n, _ := io.Copy(io.Discard, r)
		if n > 0 {
			debugf("ignored %d bytes of client data", n)
		}
	}
}

// pingLoop keeps the connection alive: WS ping every PingInterval; no pong
// within PongTimeout closes only this client (1013).
func (c *client) pingLoop() {
	t := time.NewTicker(c.hub.opts.PingInterval)
	defer t.Stop()
	for {
		select {
		case <-t.C:
			pctx, cancel := context.WithTimeout(context.Background(), c.hub.opts.PongTimeout)
			err := c.conn.Ping(pctx)
			cancel()
			if err != nil {
				debugf("client unresponsive: %v", err)
				c.beginClose(websocket.StatusTryAgainLater, "unresponsive", true)
				return
			}
		case <-c.done:
			return
		}
	}
}

// closeGraceful ends a healthy client after a bounded drain: everything
// enqueued before the decision is written before the close frame. The close
// handshake itself is performed by the writer goroutine (finish); this only
// waits for the writer to settle and, once the deadline passes, force-
// aborts a writer stuck on a peer that stopped reading (such a peer cannot
// receive the close frame anyway).
func (c *client) closeGraceful(code websocket.StatusCode, reason string, deadline time.Time) {
	decided := false
	c.once.Do(func() {
		decided = true
		for time.Now().Before(deadline) && c.sent.Load() < c.enqueued.Load() {
			time.Sleep(time.Millisecond)
		}
		c.decideClose(code, reason, false)
	})
	if !decided {
		return // the terminal close was already decided elsewhere (e.g. a drop)
	}
	// Wait outside c.once: the writer announces writerDone only after its
	// deferred removeClient returns, and removeClient's beginClose must
	// never block on an once we are holding (that would stall every later
	// client sharing this deadline and drop their queued events).
	for time.Now().Before(deadline) {
		select {
		case <-c.writerDone:
			return
		case <-time.After(time.Millisecond):
		}
	}
	if c.writeCancel != nil {
		c.writeCancel()
	}
}

func (h *Hub) removeClient(c *client) {
	h.mu.Lock()
	delete(h.clients, c)
	n := len(h.clients)
	h.mu.Unlock()
	debugf("client removed (total %d)", n)
	// No-op once the terminal close has been decided; otherwise (e.g. a
	// write failure on a vanished peer) it becomes the decision itself.
	c.beginClose(websocket.StatusNormalClosure, "removed", false)
}

// SessionActive reports whether a pipeline session is running.
func (h *Hub) SessionActive() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.sess != nil
}

// Clients reports the number of connected clients.
func (h *Hub) Clients() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.clients)
}

// Publish handles one raw NDJSON line from the pipeline stdout: session
// bookkeeping for start/eof, then a verbatim broadcast (the trailing newline
// is stripped; the line becomes exactly one WS text message).
func (h *Hub) Publish(line []byte) {
	b := bytes.TrimSuffix(line, []byte("\n"))
	b = bytes.TrimSuffix(b, []byte("\r"))
	typ, audio := eventType(b)
	if typ == "" {
		debugf("drop invalid pipeline line: %.80q", b)
		return
	}
	switch typ {
	case "start":
		h.beginSession(b, audio)
		h.broadcast(b)
	case "eof":
		h.broadcast(b)
		h.endSession(websocket.StatusNormalClosure, "session ended")
	default:
		h.broadcast(b)
	}
}

// eventType returns the type of an stt-events/1 line ("" when the line is
// not a valid JSON object) plus its audio object, when present.
func eventType(line []byte) (string, json.RawMessage) {
	var ev struct {
		Type  string          `json:"type"`
		Audio json.RawMessage `json:"audio"`
	}
	if err := json.Unmarshal(line, &ev); err != nil || ev.Type == "" {
		return "", nil
	}
	return ev.Type, ev.Audio
}

func (h *Hub) beginSession(line []byte, audio json.RawMessage) {
	now := time.Now()
	if len(audio) == 0 {
		audio = defaultAudio
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.sess = &session{
		id:        now.Format("20060102-150405"),
		startedAt: now,
		startLine: append([]byte(nil), line...),
		audio:     append(json.RawMessage(nil), audio...),
	}
	debugf("session started (id %s)", h.sess.id)
}

// endSession closes every connected client with code after a bounded drain
// and returns the hub to idle (new sessions and clients are still accepted).
func (h *Hub) endSession(code websocket.StatusCode, reason string) {
	clients := h.snapshotClients()
	h.mu.Lock()
	h.sess = nil
	h.mu.Unlock()
	deadline := time.Now().Add(h.opts.DrainTimeout)
	for _, c := range clients {
		c.closeGraceful(code, reason, deadline)
	}
	debugf("session ended (%d clients closed with %d)", len(clients), code)
}

func (h *Hub) snapshotClients() []*client {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := make([]*client, 0, len(h.clients))
	for c := range h.clients {
		out = append(out, c)
	}
	return out
}

// broadcast enqueues one event for every client. A full queue drops ONLY
// that client with 1013 (invariant I7); the pipeline never blocks.
func (h *Hub) broadcast(b []byte) {
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return
	}
	var slow []*client
	for c := range h.clients {
		c.enqueued.Add(1) // counted before the send: drain never passes early
		select {
		case c.ch <- b:
		default:
			c.enqueued.Add(-1)
			delete(h.clients, c)
			slow = append(slow, c)
		}
	}
	n := len(h.clients)
	h.mu.Unlock()
	for _, c := range slow {
		// The stuck writer is force-aborted: the peer's receive window is
		// full, so it could not read a close frame anyway.
		c.beginClose(websocket.StatusTryAgainLater, "slow client", true)
	}
	debugf("broadcast %d bytes to %d clients (%d slow)", len(b), n, len(slow))
}

// CloseClients closes every connected client with code after a bounded
// drain, ending any active session (used for fatal pipeline death: 1011).
func (h *Hub) CloseClients(code websocket.StatusCode, reason string) {
	h.endSession(code, reason)
}

// Close shuts the hub down: clients are closed with 1001 (going away), the
// listener stops. Wait is bounded by ctx.
func (h *Hub) Close(ctx context.Context) error {
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return nil
	}
	h.closed = true
	h.sess = nil
	clients := make([]*client, 0, len(h.clients))
	for c := range h.clients {
		clients = append(clients, c)
	}
	h.clients = make(map[*client]struct{})
	h.mu.Unlock()

	for _, c := range clients {
		c.closeGraceful(websocket.StatusGoingAway, "server shutting down", time.Now().Add(h.opts.DrainTimeout))
	}

	// Stop accepting. Hijacked (upgraded) connections are no longer tracked
	// by the http server, so Shutdown only waits for the listeners.
	sdone := make(chan struct{})
	go func() {
		_ = h.srv.Shutdown(context.Background())
		close(sdone)
	}()
	if err := waitCtx(ctx, sdone); err != nil {
		_ = h.srv.Close()
	}
	wdone := make(chan struct{})
	go func() {
		h.wg.Wait()
		close(wdone)
	}()
	if err := waitCtx(ctx, wdone); err != nil {
		_ = h.srv.Close()
		return fmt.Errorf("server: close timed out: %w", ctx.Err())
	}
	return nil
}

func waitCtx(ctx context.Context, done <-chan struct{}) error {
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func debugf(format string, args ...any) {
	if os.Getenv("STT_SERVER_DEBUG") != "" {
		fmt.Fprintf(os.Stderr, "[server] "+format+"\n", args...)
	}
}

// ---------------------------------------------------------------------------
// Session pipeline supervision
// ---------------------------------------------------------------------------

// PipelineOptions configures the session pipeline supervisor.
type PipelineOptions struct {
	Command       string        // session command, run verbatim via sh -c
	Dir           string        // working directory ("" = inherit)
	Hub           *Hub          // where the events are published
	MaxRestarts   int           // crash budget within RestartWindow (default 3)
	RestartWindow time.Duration // default 60 s
	RestartDelay  time.Duration // pause after a clean session before the next
	Stderr        io.Writer     // pipeline stderr sink; default os.Stderr
}

// Pipeline supervises the session command: it reads the stt-events/1 NDJSON
// from its stdout, republishes every line through the hub and applies the
// runner restart policy on crashes (docs/CONTRATOS.md §9.5).
type Pipeline struct {
	opts PipelineOptions
}

// NewPipeline returns a supervisor with the contract defaults applied.
func NewPipeline(opts PipelineOptions) *Pipeline {
	if opts.MaxRestarts <= 0 {
		opts.MaxRestarts = defaultMaxRestarts
	}
	if opts.RestartWindow <= 0 {
		opts.RestartWindow = defaultRestartWin
	}
	if opts.RestartDelay <= 0 {
		opts.RestartDelay = defaultRestartDelay
	}
	if opts.Stderr == nil {
		opts.Stderr = os.Stderr
	}
	return &Pipeline{opts: opts}
}

// synthEvent is the wire shape of the synthetic error events the supervisor
// emits on pipeline crashes ("fatal" is always present, unlike stt-events/1).
type synthEvent struct {
	Type    string `json:"type"`
	Code    string `json:"code"`
	Message string `json:"message"`
	Fatal   bool   `json:"fatal"`
}

func synthLine(code, message string, fatal bool) []byte {
	b, err := json.Marshal(synthEvent{Type: "error", Code: code, Message: message, Fatal: fatal})
	if err != nil {
		return []byte(`{"type":"error","code":"` + code + `","fatal":true}`)
	}
	return b
}

// Run supervises session after session until ctx is cancelled (returns nil)
// or the pipeline exhausts its restart budget: then the synthetic fatal
// pipeline_dead error is published, clients are closed with 1011 and the
// fatal error is returned. The HTTP server stays up either way.
func (p *Pipeline) Run(ctx context.Context) error {
	if p.opts.Hub == nil {
		return fmt.Errorf("pipeline: no hub configured")
	}
	var restarts []time.Time
	for {
		if err := ctx.Err(); err != nil {
			return nil
		}
		sawEOF, exitErr := p.runOnce(ctx)
		if ctx.Err() != nil {
			return nil // shutdown: the pipeline was stopped on purpose
		}
		if sawEOF {
			// Clean session end: the server keeps listening; wait for the
			// next session (bounded by ctx).
			if err := sleepCtx(ctx, p.opts.RestartDelay); err != nil {
				return nil
			}
			continue
		}
		// Crash: exit without eof. Restart per the runner policy.
		if p.canRestart(&restarts) {
			p.opts.Hub.Publish(synthLine("pipeline_crash", crashMessage(exitErr), false))
			continue
		}
		p.opts.Hub.Publish(synthLine("pipeline_dead", "pipeline crashed and restart budget exhausted", true))
		p.opts.Hub.CloseClients(websocket.StatusInternalError, "pipeline dead")
		return fmt.Errorf("pipeline crashed and restart budget exhausted: %w", exitErr)
	}
}

func crashMessage(exitErr error) string {
	if exitErr == nil {
		return "pipeline exited unexpectedly without eof; restarting"
	}
	return fmt.Sprintf("pipeline exited unexpectedly (%v); restarting", exitErr)
}

// runOnce executes one session pipeline. It returns whether the pipeline
// emitted eof (clean end) and the command's exit error, if any. Invalid
// stdout lines are dropped with a debug log; stderr is forwarded with a
// [pipeline] prefix.
func (p *Pipeline) runOnce(ctx context.Context) (sawEOF bool, exitErr error) {
	cmd := exec.CommandContext(ctx, "sh", "-c", p.opts.Command)
	cmd.Dir = p.opts.Dir
	// On shutdown: forward SIGINT, then hard-kill after killDelay.
	cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
	cmd.WaitDelay = killDelay

	// Own pipes: exec never closes them, so no buffered line can be lost
	// while the process is being reaped.
	outR, outW, err := os.Pipe()
	if err != nil {
		return false, err
	}
	errR, errW, err := os.Pipe()
	if err != nil {
		outR.Close()
		outW.Close()
		return false, err
	}
	cmd.Stdout, cmd.Stderr = outW, errW

	if err := cmd.Start(); err != nil {
		outR.Close()
		outW.Close()
		errR.Close()
		errW.Close()
		return false, fmt.Errorf("start pipeline: %w", err)
	}
	outW.Close()
	errW.Close()

	// Pipeline stderr: forwarded line by line with a prefix.
	errDone := make(chan struct{})
	go func() {
		defer close(errDone)
		sc := bufio.NewScanner(errR)
		sc.Buffer(make([]byte, 0, 4096), 64*1024)
		for sc.Scan() {
			fmt.Fprintf(p.opts.Stderr, "[pipeline] %s\n", sc.Bytes())
		}
		_ = errR.Close()
	}()

	// Pipeline stdout: one stt-events/1 event per line, published verbatim.
	var eof bool
	readDone := make(chan struct{})
	go func() {
		defer close(readDone)
		defer outR.Close()
		sc := bufio.NewScanner(outR)
		sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for sc.Scan() {
			line := sc.Bytes()
			typ, _ := eventType(line)
			if typ == "" {
				debugf("drop invalid pipeline line: %.80q", line)
				continue
			}
			p.opts.Hub.Publish(line)
			if typ == "eof" {
				eof = true
			}
		}
		if err := sc.Err(); err != nil {
			debugf("pipeline stdout read error: %v", err)
		}
	}()

	waitCh := make(chan error, 1)
	go func() { waitCh <- cmd.Wait() }()

	// Wait for the process to be reaped (or the shutdown to abort it), then
	// for the readers to drain: EOF arrives as soon as the child is gone.
	// The wait is bounded because descriptors inherited by misbehaving
	// grandchildren must not hang the supervisor.
	patience := time.After(2 * killDelay)
	select {
	case exitErr = <-waitCh:
	case <-ctx.Done():
		exitErr = ctx.Err()
	}
	select {
	case <-readDone:
	case <-patience:
		_ = outR.Close() // unblock the scanner (best effort)
		<-readDone
	}
	select {
	case <-errDone:
	case <-patience:
		_ = errR.Close()
		<-errDone
	}
	return eof, exitErr
}

// canRestart applies the restart budget: at most MaxRestarts within
// RestartWindow (same semantics as internal/runner).
func (p *Pipeline) canRestart(rs *[]time.Time) bool {
	now := time.Now()
	cut := now.Add(-p.opts.RestartWindow)
	kept := (*rs)[:0]
	for _, t := range *rs {
		if t.After(cut) {
			kept = append(kept, t)
		}
	}
	*rs = kept
	if len(*rs) >= p.opts.MaxRestarts {
		return false
	}
	*rs = append(*rs, now)
	return true
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
