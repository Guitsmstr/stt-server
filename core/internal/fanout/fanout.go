// Package fanout broadcasts stt-events/1 NDJSON lines to remote consumers
// over TCP or Unix sockets (docs/CONTRATOS.md §3, decision D13).
//
// The nucleus keeps stdout as its base output; --out adds a listener
// (tcp://host:port or unix:///path) that fans the same lines out to every
// connected client. A slow or disconnected client never blocks the pipeline:
// each client has a bounded queue, and a full queue disconnects that client
// only.
package fanout

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// queueLen is the per-client write queue. It absorbs short scheduling jitter;
// a client that cannot keep up is dropped instead of stalling the pipeline.
const queueLen = 256

// Hub is a fan-out listener. Write implements io.Writer and broadcasts each
// Write call as one NDJSON line (emit.Writer writes one line per call).
type Hub struct {
	ln      net.Listener
	network string
	path    string // unix socket path, removed on Close

	mu      sync.Mutex
	clients map[*client]struct{}
	start   []byte // last "start" line, replayed to late clients
	closed  bool

	wg sync.WaitGroup
}

type client struct {
	conn    net.Conn
	ch      chan []byte
	done    chan struct{}
	once    sync.Once
	writing atomic.Bool // true while the writer is flushing a line
}

func (c *client) close() {
	c.once.Do(func() {
		close(c.done)
		_ = c.conn.Close()
	})
}

// Listen starts a fan-out listener. addr must be tcp://host:port or
// unix:///absolute/path.
func Listen(addr string) (*Hub, error) {
	var (
		network, target string
	)
	switch {
	case strings.HasPrefix(addr, "tcp://"):
		network, target = "tcp", strings.TrimPrefix(addr, "tcp://")
	case strings.HasPrefix(addr, "unix://"):
		network, target = "unix", strings.TrimPrefix(addr, "unix://")
	default:
		return nil, fmt.Errorf("fanout: unsupported address %q (use tcp://host:port or unix:///path)", addr)
	}
	if target == "" {
		return nil, fmt.Errorf("fanout: empty address in %q", addr)
	}

	path := ""
	if network == "unix" {
		if !strings.HasPrefix(target, "/") {
			return nil, fmt.Errorf("fanout: unix socket path must be absolute: %q", target)
		}
		path = target
		// A crash can leave the socket behind. Remove it only when it really
		// is a socket; never delete a regular file by accident.
		if fi, err := os.Stat(path); err == nil {
			if fi.Mode()&os.ModeSocket == 0 {
				return nil, fmt.Errorf("fanout: %s exists and is not a socket", path)
			}
			if err := os.Remove(path); err != nil {
				return nil, fmt.Errorf("fanout: remove stale socket: %w", err)
			}
		} else if !errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("fanout: stat %s: %w", path, err)
		}
	}

	ln, err := net.Listen(network, target)
	if err != nil {
		return nil, fmt.Errorf("fanout: listen %s: %w", addr, err)
	}
	h := &Hub{
		ln:      ln,
		network: network,
		path:    path,
		clients: make(map[*client]struct{}),
	}
	h.wg.Add(1)
	go h.acceptLoop()
	return h, nil
}

// Addr returns the bound address (useful with port 0 in tests).
func (h *Hub) Addr() string { return h.ln.Addr().String() }

// Clients reports the number of connected clients.
func (h *Hub) Clients() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.clients)
}

func (h *Hub) acceptLoop() {
	defer h.wg.Done()
	for {
		conn, err := h.ln.Accept()
		if err != nil {
			return // listener closed
		}
		h.add(conn)
	}
}

func debugf(format string, args ...any) {
	if os.Getenv("STT_FANOUT_DEBUG") != "" {
		fmt.Fprintf(os.Stderr, "[fanout] "+format+"\n", args...)
	}
}

func (h *Hub) add(conn net.Conn) {
	c := &client{
		conn: conn,
		ch:   make(chan []byte, queueLen),
		done: make(chan struct{}),
	}
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		c.close()
		return
	}
	// Replay the header contract to clients that connect after start.
	if h.start != nil {
		c.ch <- h.start
	}
	h.clients[c] = struct{}{}
	debugf("add client (total %d, start replay %v)", len(h.clients), h.start != nil)
	h.mu.Unlock()

	h.wg.Add(1)
	go func() {
		defer h.wg.Done()
		// Clients are receive-only. Reading also detects a peer disconnect
		// immediately (without waiting for the next broadcast to fail).
		_, _ = io.Copy(io.Discard, conn)
		c.close()
	}()

	h.wg.Add(1)
	go func() {
		defer h.wg.Done()
		defer h.remove(c)
		w := bufio.NewWriter(conn)
		for {
			select {
			case line := <-c.ch:
				c.writing.Store(true)
				if _, err := w.Write(line); err != nil {
					c.writing.Store(false)
					debugf("client write error: %v", err)
					c.close()
					return
				}
				if err := w.Flush(); err != nil {
					c.writing.Store(false)
					debugf("client flush error: %v", err)
					c.close()
					return
				}
				c.writing.Store(false)
			case <-c.done:
				return
			}
		}
	}()
}

func (h *Hub) remove(c *client) {
	h.mu.Lock()
	delete(h.clients, c)
	n := len(h.clients)
	h.mu.Unlock()
	debugf("remove client (total %d)", n)
	c.close()
}

// Write broadcasts one complete NDJSON line (with trailing newline) to every
// connected client. It never blocks on a client: a full queue disconnects it.
func (h *Hub) Write(p []byte) (int, error) {
	line := make([]byte, len(p))
	copy(line, p)
	if len(line) > 0 && line[len(line)-1] == '\n' {
		trimmed := line[:len(line)-1]
		if isStart(trimmed) {
			h.mu.Lock()
			h.start = append([]byte(nil), line...)
			h.mu.Unlock()
		}
	}

	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return len(p), nil // best effort: the pipeline must not fail on shutdown
	}
	var slow []*client
	for c := range h.clients {
		select {
		case c.ch <- line:
		default:
			slow = append(slow, c)
		}
	}
	for _, c := range slow {
		delete(h.clients, c)
		c.close()
	}
	debugf("write %d bytes to %d clients (%d slow)", len(p), len(h.clients), len(slow))
	h.mu.Unlock()
	return len(p), nil
}

func isStart(line []byte) bool {
	// Cheap prefix check; start is the first event after --out is listening.
	const prefix = `{"type":"start"`
	return len(line) >= len(prefix) && string(line[:len(prefix)]) == prefix
}

// Close stops the listener, disconnects clients and removes a unix socket.
func (h *Hub) Close() error {
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return nil
	}
	h.closed = true
	_ = h.ln.Close()
	pending := make([]*client, 0, len(h.clients))
	for c := range h.clients {
		pending = append(pending, c)
	}
	h.clients = make(map[*client]struct{})
	h.mu.Unlock()

	// Drain queues before closing: the last event (eof) was just enqueued and
	// clients must see it. A client that stopped reading is dropped at the
	// deadline instead of blocking shutdown.
	deadline := time.Now().Add(2 * time.Second)
	for _, c := range pending {
		for time.Now().Before(deadline) {
			if len(c.ch) == 0 && !c.writing.Load() {
				break
			}
			time.Sleep(time.Millisecond)
		}
	}
	for _, c := range pending {
		c.close()
	}
	h.wg.Wait()
	if h.path != "" {
		_ = os.Remove(h.path)
	}
	return nil
}
