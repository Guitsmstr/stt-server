package server

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// testToken is a fixed 64-hex-char token (no randomness in tests).
const testToken = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

const testTimeout = 10 * time.Second

func testOptions() Options {
	return Options{
		Listen:       "127.0.0.1:0",
		Token:        testToken,
		MaxClients:   8,
		QueueLen:     256,
		PingInterval: time.Hour, // no keepalive noise in unrelated tests
		PongTimeout:  time.Hour,
		DrainTimeout: 2 * time.Second,
	}
}

func newHub(t *testing.T, opts Options) *Hub {
	t.Helper()
	h, err := New(opts)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	h.Serve()
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = h.Close(ctx)
	})
	return h
}

// wsClient is a test WebSocket consumer: it reads messages in the
// background and exposes them through channels.
type wsClient struct {
	conn   *websocket.Conn
	msgs   chan []byte
	errc   chan error
	cancel context.CancelFunc
}

// dialFeed dials /v1/feed with the given header entries and query string.
// On success it starts a read loop and returns the client.
func dialFeed(t *testing.T, h *Hub, header map[string]string, query string) (*wsClient, *http.Response, error) {
	t.Helper()
	opts := &websocket.DialOptions{HTTPHeader: http.Header{}}
	for k, v := range header {
		opts.HTTPHeader.Set(k, v)
	}
	ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
	defer cancel()
	conn, resp, err := websocket.Dial(ctx, "ws://"+h.Addr()+"/v1/feed"+query, opts)
	if err != nil {
		return nil, resp, err
	}
	c := &wsClient{
		conn: conn,
		msgs: make(chan []byte, 1024),
		errc: make(chan error, 1),
	}
	rctx, rcancel := context.WithCancel(context.Background())
	c.cancel = rcancel
	go c.readLoop(rctx)
	t.Cleanup(func() {
		rcancel()
		_ = conn.CloseNow()
	})
	return c, resp, nil
}

// dialAuth connects with the valid bearer token.
func dialAuth(t *testing.T, h *Hub) *wsClient {
	t.Helper()
	c, _, err := dialFeed(t, h, map[string]string{"Authorization": "Bearer " + testToken}, "")
	if err != nil {
		t.Fatalf("dial with valid token: %v", err)
	}
	return c
}

func (c *wsClient) readLoop(ctx context.Context) {
	for {
		_, r, err := c.conn.Reader(ctx)
		if err != nil {
			c.errc <- err
			return
		}
		b, err := io.ReadAll(r)
		if err != nil {
			c.errc <- err
			return
		}
		select {
		case c.msgs <- b:
		case <-ctx.Done():
			return
		}
	}
}

// next returns the next data message (failing on connection error/timeout).
// Buffered messages win over a connection error: on a clean close the
// reader goroutine stocks the final events and the close error back to
// back, and every delivered event must be observable before the close.
func (c *wsClient) next(t *testing.T, what string) []byte {
	t.Helper()
	select {
	case b := <-c.msgs:
		return b
	default:
	}
	select {
	case b := <-c.msgs:
		return b
	case err := <-c.errc:
		t.Fatalf("%s: connection ended early: %v", what, err)
	case <-time.After(testTimeout):
		t.Fatalf("%s: timed out waiting for a message", what)
	}
	return nil
}

// waitClose drains the remaining messages and asserts the close code.
func (c *wsClient) waitClose(t *testing.T, want websocket.StatusCode, what string) {
	t.Helper()
	for {
		select {
		case <-c.msgs:
			continue
		case err := <-c.errc:
			if got := websocket.CloseStatus(err); got != want {
				t.Fatalf("%s: close status = %d (%v), want %d", what, got, err, want)
			}
			return
		case <-time.After(testTimeout):
			t.Fatalf("%s: timed out waiting for close %d", what, want)
		}
	}
}

// waitFor polls observable state until fn holds (no sleep-based sync).
func waitFor(t *testing.T, what string, fn func() bool) {
	t.Helper()
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		if fn() {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func healthzGet(t *testing.T, h *Hub) (int, string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+h.Addr()+"/healthz", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("healthz: %v", err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

const startLine = `{"type":"start","audio":{"rate":16000,"channels":1,"format":"s16le"}}`

// fixtureEvents is the 10-event session fixture: start, 3 partials,
// 4 finals, one error and eof.
func fixtureEvents() []string {
	evs := []string{startLine}
	for i := 0; i < 3; i++ {
		evs = append(evs, fmt.Sprintf(`{"type":"partial","text":"partial %d","t0":%.1f,"t1":%.1f}`, i, float64(i), float64(i)+0.5))
	}
	for i := 0; i < 4; i++ {
		evs = append(evs, fmt.Sprintf(`{"type":"final","text":"final %d","t0":%.1f,"t1":%.1f}`, i+3, float64(i+3), float64(i+4)))
	}
	evs = append(evs, `{"type":"error","code":"model","message":"boom","fatal":false}`)
	evs = append(evs, `{"type":"eof","frames":8,"audio_s":8.0}`)
	return evs
}

func publishAll(h *Hub, evs []string) {
	for _, e := range evs {
		h.Publish([]byte(e + "\n"))
	}
}

func TestHealthz(t *testing.T) {
	h := newHub(t, testOptions())

	code, body := healthzGet(t, h)
	want := `{"status":"ok","protocol":"stt-remote/1","session":false}` + "\n"
	if code != http.StatusOK || body != want {
		t.Fatalf("idle healthz = (%d, %q), want (200, %q)", code, body, want)
	}

	h.Publish([]byte(startLine + "\n"))
	waitFor(t, "session active", h.SessionActive)
	code, body = healthzGet(t, h)
	want = `{"status":"ok","protocol":"stt-remote/1","session":true}` + "\n"
	if code != http.StatusOK || body != want {
		t.Fatalf("active healthz = (%d, %q), want (200, %q)", code, body, want)
	}

	h.Publish([]byte(`{"type":"eof","frames":1,"audio_s":1.0}` + "\n"))
	waitFor(t, "session idle again", func() bool { return !h.SessionActive() })
	code, body = healthzGet(t, h)
	want = `{"status":"ok","protocol":"stt-remote/1","session":false}` + "\n"
	if code != http.StatusOK || body != want {
		t.Fatalf("post-eof healthz = (%d, %q), want (200, %q)", code, body, want)
	}
}

func TestAuthRejects(t *testing.T) {
	h := newHub(t, testOptions())

	reject := func(name string, header map[string]string, query string) {
		t.Helper()
		c, resp, err := dialFeed(t, h, header, query)
		if err == nil {
			c.cancel()
			_ = c.conn.CloseNow()
			t.Fatalf("%s: connection must be rejected before the upgrade", name)
		}
		if resp == nil || resp.StatusCode != http.StatusUnauthorized {
			status := 0
			if resp != nil {
				status = resp.StatusCode
			}
			t.Fatalf("%s: status = %d, want 401 (before the upgrade)", name, status)
		}
		body, _ := io.ReadAll(resp.Body)
		if string(body) != "unauthorized\n" {
			t.Fatalf("%s: body = %q, want %q", name, body, "unauthorized\n")
		}
	}

	reject("no token", nil, "")
	reject("wrong token", map[string]string{"Authorization": "Bearer " + strings.Repeat("ff", 32)}, "")
	reject("empty bearer", map[string]string{"Authorization": "Bearer "}, "")
	reject("empty query token", nil, "?token=")
	reject("wrong query token", nil, "?token=deadbeef")
	// No hint about anything, and no client registered.
	waitFor(t, "no clients registered", func() bool { return h.Clients() == 0 })

	// Valid token via header and via query fallback connect.
	if c, _, err := dialFeed(t, h, map[string]string{"Authorization": "Bearer " + testToken}, ""); err != nil {
		t.Fatalf("valid header token: %v", err)
	} else {
		hello := c.next(t, "hello (header)")
		checkHello(t, hello, false)
	}
	if c, _, err := dialFeed(t, h, nil, "?token="+testToken); err != nil {
		t.Fatalf("valid query token: %v", err)
	} else {
		hello := c.next(t, "hello (query)")
		checkHello(t, hello, false)
	}
	waitFor(t, "two clients", func() bool { return h.Clients() == 2 })
}

// checkHello asserts the hello message; withSession requires a non-null
// session object (and returns it).
func checkHello(t *testing.T, msg []byte, withSession bool) map[string]any {
	t.Helper()
	var m struct {
		Type     string          `json:"type"`
		Protocol string          `json:"protocol"`
		Server   string          `json:"server"`
		Session  json.RawMessage `json:"session"`
	}
	if err := json.Unmarshal(msg, &m); err != nil {
		t.Fatalf("hello is not JSON: %v (%q)", err, msg)
	}
	if m.Type != "hello" || m.Protocol != "stt-remote/1" || m.Server != "sttd/0.1" {
		t.Fatalf("hello = %q", msg)
	}
	if !withSession {
		if string(m.Session) != "null" {
			t.Fatalf("hello.session = %s, want null", m.Session)
		}
		return nil
	}
	var sess map[string]any
	if err := json.Unmarshal(m.Session, &sess); err != nil {
		t.Fatalf("hello.session is not an object: %v", err)
	}
	return sess
}

func TestHelloLazyAttach(t *testing.T) {
	h := newHub(t, testOptions())
	c := dialAuth(t, h)

	hello := c.next(t, "hello")
	checkHello(t, hello, false)

	// An invalid line is dropped: the next message this client sees is the
	// start event itself (the hello was the ONLY message while idle).
	h.Publish([]byte("this is not json\n"))
	h.Publish([]byte(startLine + "\n"))
	if got := string(c.next(t, "start")); got != startLine {
		t.Fatalf("got %q, want the verbatim start line", got)
	}
	partial := `{"type":"partial","text":"lazy","t0":0,"t1":0.5}`
	h.Publish([]byte(partial + "\n"))
	if got := string(c.next(t, "partial")); got != partial {
		t.Fatalf("got %q, want %q", got, partial)
	}
}

func TestHelloActiveSession(t *testing.T) {
	opts := testOptions()
	opts.Engine = "moonshine-tiny"
	opts.Partials = true
	h := newHub(t, opts)

	h.Publish([]byte(startLine + "\n"))
	waitFor(t, "session active", h.SessionActive)

	c := dialAuth(t, h)
	sess := checkHello(t, c.next(t, "hello with session"), true)
	if id, _ := sess["id"].(string); len(id) != 15 || id[8] != '-' {
		t.Fatalf("session.id = %v, want YYYYMMDD-HHMMSS", sess["id"])
	}
	if sess["engine"] != "moonshine-tiny" || sess["partials"] != true {
		t.Fatalf("session = %v", sess)
	}
	if started, _ := sess["started_at"].(string); started == "" {
		t.Fatalf("session.started_at missing: %v", sess)
	} else if _, err := time.Parse(time.RFC3339, started); err != nil {
		t.Fatalf("started_at %q is not RFC3339: %v", started, err)
	}
	var audio map[string]any
	if b, err := json.Marshal(sess["audio"]); err != nil {
		t.Fatal(err)
	} else if err := json.Unmarshal(b, &audio); err != nil {
		t.Fatal(err)
	}
	if audio["rate"] != float64(16000) || audio["channels"] != float64(1) || audio["format"] != "s16le" {
		t.Fatalf("session.audio = %v", audio)
	}

	// The replayed raw start line is the very next message.
	if got := string(c.next(t, "start replay")); got != startLine {
		t.Fatalf("replay = %q, want %q", got, startLine)
	}
	// ...and live events continue after it, in order.
	final := `{"type":"final","text":"late","t0":1,"t1":2}`
	h.Publish([]byte(final + "\n"))
	if got := string(c.next(t, "live final")); got != final {
		t.Fatalf("got %q, want %q", got, final)
	}
}

func TestEventOrderVerbatim(t *testing.T) {
	h := newHub(t, testOptions())
	evs := fixtureEvents()

	clients := []*wsClient{dialAuth(t, h), dialAuth(t, h)}
	for _, c := range clients {
		checkHello(t, c.next(t, "hello"), false)
	}

	publishAll(h, evs)
	for i, c := range clients {
		for n, want := range evs {
			if got := string(c.next(t, fmt.Sprintf("client %d event %d", i, n))); got != want {
				t.Fatalf("client %d event %d = %q, want %q", i, n, got, want)
			}
		}
		c.waitClose(t, websocket.StatusNormalClosure, fmt.Sprintf("client %d close", i))
	}
	waitFor(t, "clients gone after eof", func() bool { return h.Clients() == 0 })
	waitFor(t, "session idle after eof", func() bool { return !h.SessionActive() })
}

func TestManyClients(t *testing.T) {
	h := newHub(t, testOptions())
	var clients []*wsClient
	for i := 0; i < 4; i++ {
		clients = append(clients, dialAuth(t, h))
	}
	for i, c := range clients {
		checkHello(t, c.next(t, fmt.Sprintf("client %d hello", i)), false)
	}

	evs := []string{startLine}
	for i := 0; i < 8; i++ {
		evs = append(evs, fmt.Sprintf(`{"type":"final","text":"f %d","t0":%d,"t1":%d}`, i, i, i+1))
	}
	// One client disconnects mid-session; the rest must not notice.
	h.Publish([]byte(evs[0] + "\n"))
	h.Publish([]byte(evs[1] + "\n"))
	clients[1].cancel()
	_ = clients[1].conn.CloseNow()
	waitFor(t, "disconnected client removed", func() bool { return h.Clients() == 3 })
	for _, e := range evs[2:] {
		h.Publish([]byte(e + "\n"))
	}
	h.Publish([]byte(`{"type":"eof","frames":8,"audio_s":8}` + "\n"))

	for i, c := range clients {
		if i == 1 {
			continue
		}
		for n, want := range evs {
			if got := string(c.next(t, fmt.Sprintf("client %d event %d", i, n))); got != want {
				t.Fatalf("client %d event %d = %q, want %q", i, n, got, want)
			}
		}
		c.waitClose(t, websocket.StatusNormalClosure, fmt.Sprintf("client %d close", i))
	}
}

func TestMaxClients(t *testing.T) {
	opts := testOptions()
	opts.MaxClients = 2
	h := newHub(t, opts)

	c1 := dialAuth(t, h)
	c2 := dialAuth(t, h)
	waitFor(t, "two clients", func() bool { return h.Clients() == 2 })

	_, resp, err := dialFeed(t, h, map[string]string{"Authorization": "Bearer " + testToken}, "")
	if err == nil {
		t.Fatal("third client must be rejected")
	}
	if resp == nil || resp.StatusCode != http.StatusServiceUnavailable {
		status := 0
		if resp != nil {
			status = resp.StatusCode
		}
		t.Fatalf("third client status = %d, want 503", status)
	}

	// A slot frees up when a client leaves.
	c1.cancel()
	_ = c1.conn.CloseNow()
	waitFor(t, "slot freed", func() bool { return h.Clients() == 1 })
	c3 := dialAuth(t, h)
	checkHello(t, c3.next(t, "hello after slot freed"), false)
	_ = c2
}

// slowDialer builds an HTTP client whose sockets get a tiny SO_RCVBUF set
// BEFORE connecting, so kernel buffering cannot mask backpressure.
func slowDialer() *http.Client {
	d := &net.Dialer{
		Control: func(network, address string, rc syscall.RawConn) error {
			var serr error
			err := rc.Control(func(fd uintptr) {
				serr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_RCVBUF, 1024)
			})
			if err != nil {
				return err
			}
			return serr
		},
	}
	return &http.Client{Transport: &http.Transport{DialContext: d.DialContext}}
}

func TestSlowClientDropped(t *testing.T) {
	opts := testOptions()
	opts.QueueLen = 2 // tiny per-client queue
	closes := make(chan websocket.StatusCode, 64)
	opts.OnClientClose = func(code websocket.StatusCode, _ string) {
		select {
		case closes <- code:
		default:
		}
	}
	h := newHub(t, opts)

	healthy := dialAuth(t, h)
	checkHello(t, healthy.next(t, "healthy hello"), false)
	// The slow client never reads; its socket receive buffer is minimal.
	slowConn, _, err := websocket.Dial(context.Background(), "ws://"+h.Addr()+"/v1/feed", &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": []string{"Bearer " + testToken}},
		HTTPClient: slowDialer(),
	})
	if err != nil {
		t.Fatalf("slow dial: %v", err)
	}
	t.Cleanup(func() { _ = slowConn.CloseNow() })
	waitFor(t, "two clients", func() bool { return h.Clients() == 2 })

	// Publish line by line, each one acknowledged by the healthy client (so
	// its own queue always drains: only the silent client can overflow).
	h.Publish([]byte(startLine + "\n"))
	if got := string(healthy.next(t, "healthy start")); got != startLine {
		t.Fatalf("got %q", got)
	}
	dropped := false
	// ~31 KB lines: a few hundred of them exceed the kernel send buffer
	// (initial 1 MiB, autotuned up to 4 MiB) even though the slow client's
	// receive window is ~2 KiB, so the writer goroutine blocks on the socket
	// and the 2-deep queue overflows: real backpressure, no timing
	// assumptions. (Still under the library's 32 KiB default read limit, so
	// the healthy client is unaffected.)
	pad := strings.Repeat("x", 31000)
	for i := 0; i < 400; i++ {
		line := fmt.Sprintf(`{"type":"final","text":"flood %04d %s","t0":%d,"t1":%d}`, i, pad, i, i+1)
		h.Publish([]byte(line + "\n"))
		if got := string(healthy.next(t, "healthy event")); got != line {
			t.Fatalf("healthy client got %q, want %q", got, line)
		}
		if h.Clients() == 1 {
			dropped = true
			break
		}
	}
	if !dropped {
		t.Fatal("slow client was never dropped")
	}

	// The drop used 1013 (observed server-side: the close frame may not be
	// readable on a socket whose buffer is already full).
	saw1013 := false
sawCode:
	for {
		select {
		case code := <-closes:
			if code == websocket.StatusTryAgainLater {
				saw1013 = true
				break sawCode
			}
		default:
			break sawCode
		}
	}
	if !saw1013 {
		t.Fatal("slow client was not closed with 1013")
	}

	// The healthy client still receives everything, including eof + 1000.
	h.Publish([]byte(`{"type":"eof","frames":400,"audio_s":400}` + "\n"))
	healthy.waitClose(t, websocket.StatusNormalClosure, "healthy close after slow drop")
}

func TestPingPongTimeout(t *testing.T) {
	opts := testOptions()
	opts.PingInterval = 50 * time.Millisecond
	opts.PongTimeout = 150 * time.Millisecond
	closes := make(chan websocket.StatusCode, 16)
	opts.OnClientClose = func(code websocket.StatusCode, _ string) {
		select {
		case closes <- code:
		default:
		}
	}
	h := newHub(t, opts)

	// This client connects but never reads: it never answers pings.
	conn, _, err := websocket.Dial(context.Background(), "ws://"+h.Addr()+"/v1/feed", &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": []string{"Bearer " + testToken}},
	})
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = conn.CloseNow() })

	waitFor(t, "unresponsive client dropped", func() bool { return h.Clients() == 0 })
	select {
	case code := <-closes:
		if code != websocket.StatusTryAgainLater {
			t.Fatalf("close code = %d, want 1013", code)
		}
	default:
		t.Fatal("no close observed for the unresponsive client")
	}

	// The buffered messages (hello, pings) drain first; the close frame
	// carries the status to this late reader.
	ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
	defer cancel()
	for {
		_, r, rerr := conn.Reader(ctx)
		if rerr == nil {
			_, _ = io.Copy(io.Discard, r)
			continue
		}
		if got := websocket.CloseStatus(rerr); got != websocket.StatusTryAgainLater {
			t.Fatalf("client close status = %d (%v), want 1013", got, rerr)
		}
		break
	}
}

func TestServerClose1001(t *testing.T) {
	h := newHub(t, testOptions())
	c1 := dialAuth(t, h)
	c2 := dialAuth(t, h)
	checkHello(t, c1.next(t, "hello"), false)
	checkHello(t, c2.next(t, "hello"), false)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := h.Close(ctx); err != nil {
		t.Fatalf("Close: %v", err)
	}
	c1.waitClose(t, websocket.StatusGoingAway, "client 1 close")
	c2.waitClose(t, websocket.StatusGoingAway, "client 2 close")
	if h.SessionActive() {
		t.Fatal("hub must be idle after Close")
	}
	// Idempotent.
	if err := h.Close(ctx); err != nil {
		t.Fatalf("second Close: %v", err)
	}
}

func TestPipelineHappyPath(t *testing.T) {
	h := newHub(t, testOptions())
	c := dialAuth(t, h)
	checkHello(t, c.next(t, "hello"), false)

	evs := []string{
		startLine,
		`{"type":"final","text":"ever tried ever failed","t0":0.13,"t1":1.44,"model":"echo"}`,
		`{"type":"eof","frames":1,"audio_s":1.5}`,
	}
	// The supervisor runs the command via sh -c already; a printf emits the
	// fixture lines on stdout.
	cmd := "printf '" + strings.Join(evs, "\\n") + "\\n'"

	pl := NewPipeline(PipelineOptions{
		Command:       cmd,
		Hub:           h,
		MaxRestarts:   3,
		RestartWindow: time.Minute,
		RestartDelay:  time.Hour, // no second session while the test asserts
		Stderr:        io.Discard,
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	plDone := make(chan error, 1)
	go func() { plDone <- pl.Run(ctx) }()

	for _, want := range evs {
		if got := string(c.next(t, "pipeline event "+want[:16])); got != want {
			t.Fatalf("got %q, want %q", got, want)
		}
	}
	c.waitClose(t, websocket.StatusNormalClosure, "close after pipeline eof")
	waitFor(t, "session idle after pipeline eof", func() bool { return !h.SessionActive() })

	cancel()
	select {
	case err := <-plDone:
		if err != nil {
			t.Fatalf("pipeline Run: %v", err)
		}
	case <-time.After(testTimeout):
		t.Fatal("pipeline Run did not return after cancel")
	}
}

func TestPipelineRestartBudget(t *testing.T) {
	h := newHub(t, testOptions())
	c := dialAuth(t, h)
	checkHello(t, c.next(t, "hello"), false)

	pl := NewPipeline(PipelineOptions{
		Command:       "exit 3", // crashes immediately, without eof
		Hub:           h,
		MaxRestarts:   2,
		RestartWindow: time.Minute,
		Stderr:        io.Discard,
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	plDone := make(chan error, 1)
	go func() { plDone <- pl.Run(ctx) }()

	// MaxRestarts = 2: two crash notifications, then the fatal one.
	for i := 0; i < 2; i++ {
		ev := readEvent(t, c)
		if ev["code"] != "pipeline_crash" || ev["fatal"] != false {
			t.Fatalf("restart %d event = %v, want pipeline_crash fatal:false", i, ev)
		}
	}
	ev := readEvent(t, c)
	if ev["code"] != "pipeline_dead" || ev["fatal"] != true {
		t.Fatalf("final event = %v, want pipeline_dead fatal:true", ev)
	}
	c.waitClose(t, websocket.StatusInternalError, "close after pipeline death")

	select {
	case err := <-plDone:
		if err == nil || !strings.Contains(err.Error(), "restart budget exhausted") {
			t.Fatalf("Run error = %v, want exhausted budget", err)
		}
	case <-time.After(testTimeout):
		t.Fatal("Run did not return after fatal")
	}
	if h.SessionActive() {
		t.Fatal("session must end after pipeline death")
	}

	// The HTTP server stays up (healthz + new clients with session:null).
	if _, body := healthzGet(t, h); !strings.Contains(body, `"session":false`) {
		t.Fatalf("healthz after death = %q", body)
	}
	c2 := dialAuth(t, h)
	checkHello(t, c2.next(t, "hello after death"), false)
}

func readEvent(t *testing.T, c *wsClient) map[string]any {
	t.Helper()
	var ev map[string]any
	msg := c.next(t, "synthetic error event")
	if err := json.Unmarshal(msg, &ev); err != nil {
		t.Fatalf("event is not JSON: %v (%q)", err, msg)
	}
	if ev["type"] != "error" {
		t.Fatalf("event = %q, want an error event", msg)
	}
	return ev
}

// TestPublishDropsInvalidLines guards the verbatim rule: only valid
// stt-events/1 objects are broadcast, junk never reaches clients.
func TestPublishDropsInvalidLines(t *testing.T) {
	h := newHub(t, testOptions())
	c := dialAuth(t, h)
	checkHello(t, c.next(t, "hello"), false)

	h.Publish([]byte("\n"))
	h.Publish([]byte("not json\n"))
	h.Publish([]byte(`[1,2,3]` + "\n"))
	h.Publish([]byte(`{"text":"missing type"}` + "\n"))
	line := `{"type":"final","text":"kept","t0":0,"t1":1}`
	h.Publish([]byte(line + "\n"))

	if got := string(c.next(t, "first message after junk")); got != line {
		t.Fatalf("got %q, want %q (junk must be dropped silently)", got, line)
	}
}
