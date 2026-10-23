package fanout

import (
	"bufio"
	"net"
	"strings"
	"testing"
	"time"
)

func readLine(t *testing.T, r *bufio.Scanner) string {
	t.Helper()
	if !r.Scan() {
		t.Fatalf("scanner stopped: %v", r.Err())
	}
	return r.Text()
}

func TestTCPFanoutTwoClientsAndLateJoin(t *testing.T) {
	h, err := Listen("tcp://127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	c1, err := net.Dial("tcp", h.Addr())
	if err != nil {
		t.Fatal(err)
	}
	defer c1.Close()
	c2, err := net.Dial("tcp", h.Addr())
	if err != nil {
		t.Fatal(err)
	}
	defer c2.Close()
	waitClients(t, h, 2)

	start := `{"type":"start","audio":{"rate":16000,"channels":1,"format":"s16le"}}` + "\n"
	ev := `{"type":"final","text":"hola","t0":0,"t1":1}` + "\n"
	if _, err := h.Write([]byte(start)); err != nil {
		t.Fatal(err)
	}
	if _, err := h.Write([]byte(ev)); err != nil {
		t.Fatal(err)
	}

	for i, c := range []net.Conn{c1, c2} {
		s := bufio.NewScanner(c)
		if got := readLine(t, s); got != strings.TrimSuffix(start, "\n") {
			t.Fatalf("client %d start = %q", i, got)
		}
		if got := readLine(t, s); got != strings.TrimSuffix(ev, "\n") {
			t.Fatalf("client %d event = %q", i, got)
		}
	}

	// A client that connects after start receives the replay, then live events.
	c3, err := net.Dial("tcp", h.Addr())
	if err != nil {
		t.Fatal(err)
	}
	defer c3.Close()
	waitClients(t, h, 3)
	s3 := bufio.NewScanner(c3)
	if got := readLine(t, s3); got != strings.TrimSuffix(start, "\n") {
		t.Fatalf("late client start replay = %q", got)
	}
	if _, err := h.Write([]byte(ev)); err != nil {
		t.Fatal(err)
	}
	if got := readLine(t, s3); got != strings.TrimSuffix(ev, "\n") {
		t.Fatalf("late client event = %q", got)
	}
}

func TestDisconnectDoesNotAffectOtherClients(t *testing.T) {
	h, err := Listen("tcp://127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	c1, err := net.Dial("tcp", h.Addr())
	if err != nil {
		t.Fatal(err)
	}
	defer c1.Close()
	c2, err := net.Dial("tcp", h.Addr())
	if err != nil {
		t.Fatal(err)
	}
	waitClients(t, h, 2)
	_ = c2.Close()

	// The hub learns about the disconnect on the next broadcast; that write
	// must still reach the surviving client and must not block.
	line := `{"type":"final","text":"still here"}` + "\n"
	if _, err := h.Write([]byte(line)); err != nil {
		t.Fatal(err)
	}
	waitClients(t, h, 1)
	s1 := bufio.NewScanner(c1)
	if got := readLine(t, s1); got != strings.TrimSuffix(line, "\n") {
		t.Fatalf("surviving client got %q", got)
	}
}

func TestUnixSocket(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/stt.sock"
	h, err := Listen("unix://" + path)
	if err != nil {
		t.Fatal(err)
	}
	c, err := net.Dial("unix", path)
	if err != nil {
		_ = h.Close()
		t.Fatal(err)
	}
	defer c.Close()
	waitClients(t, h, 1)
	line := `{"type":"final","text":"unix"}` + "\n"
	if _, err := h.Write([]byte(line)); err != nil {
		t.Fatal(err)
	}
	s := bufio.NewScanner(c)
	if got := readLine(t, s); got != strings.TrimSuffix(line, "\n") {
		t.Fatalf("unix client got %q", got)
	}
	if err := h.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := net.Dial("unix", path); err == nil {
		t.Fatal("socket must be removed on Close")
	}
}

func TestBadAddress(t *testing.T) {
	if _, err := Listen("http://127.0.0.1:1"); err == nil {
		t.Fatal("unsupported scheme must error")
	}
	if _, err := Listen("unix://relative.sock"); err == nil {
		t.Fatal("relative unix path must error")
	}
}

func waitClients(t *testing.T, h *Hub, want int) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if h.Clients() == want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("clients = %d, want %d", h.Clients(), want)
}
