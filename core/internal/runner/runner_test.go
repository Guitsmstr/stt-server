package runner

import (
	"context"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"stt/internal/protocol"
)

var adapterBin string

func TestMain(m *testing.M) {
	dir := filepath.Join("..", "..", "..", "adapters", "echo")
	out, err := exec.Command("make", "-C", dir).CombinedOutput()
	if err != nil {
		fmt.Fprintf(os.Stderr, "build echo adapter: %v\n%s", err, out)
		os.Exit(1)
	}
	adapterBin = filepath.Join(dir, "stt-adapter-echo")
	os.Exit(m.Run())
}

func testHeader(frameMs int) protocol.Header {
	return protocol.Header{
		Protocol: protocol.Version,
		Audio:    protocol.AudioFormat{Rate: 16000, Channels: 1, Format: "s16le"},
		FrameMs:  frameMs,
	}
}

// TestProtocolIntegrity (S1.3) speaks stt-adapter/1 directly to the C++
// echo adapter: >1 MiB of deterministic frames must arrive uncorrupted
// (verified with the adapter-reported FNV-1a checksum and byte count).
func TestProtocolIntegrity(t *testing.T) {
	cmd := exec.Command(adapterBin, "--model", "echo-integrity")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = cmd.Wait() }()

	w, err := protocol.NewWriter(stdin, testHeader(256))
	if err != nil {
		t.Fatal(err)
	}
	h := fnv.New64a()
	total := 0

	// 256 frames x 4096 B = 1 MiB, plus a 23 B tail frame.
	for i := 0; i < 256; i++ {
		fr := make([]byte, 4096)
		for j := range fr {
			fr[j] = byte(i*7 + j*13)
		}
		h.Write(fr)
		total += len(fr)
		if err := w.WriteFrame(fr); err != nil {
			t.Fatal(err)
		}
	}
	tail := make([]byte, 23)
	for i := range tail {
		tail[i] = byte(i * 31)
	}
	h.Write(tail)
	total += len(tail)
	if err := w.WriteFrame(tail); err != nil {
		t.Fatal(err)
	}
	stdin.Close()

	rd := protocol.NewEventReader(stdout)
	raw, err := rd.NextRaw()
	if err != nil {
		t.Fatalf("no ready event: %v", err)
	}
	var ready map[string]any
	if err := json.Unmarshal(raw, &ready); err != nil {
		t.Fatal(err)
	}
	if ready["type"] != "ready" || ready["protocol"] != protocol.Version {
		t.Fatalf("bad ready event: %s", raw)
	}

	finals := 0
	var bye map[string]any
	for {
		raw, err := rd.NextRaw()
		if err != nil {
			break
		}
		var ev map[string]any
		if err := json.Unmarshal(raw, &ev); err != nil {
			t.Fatalf("invalid event line: %s", raw)
		}
		switch ev["type"] {
		case "final":
			finals++
		case "bye":
			bye = ev
		}
	}
	if finals != 257 {
		t.Fatalf("finals = %d, want 257", finals)
	}
	if bye == nil {
		t.Fatal("no bye event")
	}
	if int(bye["bytes"].(float64)) != total {
		t.Fatalf("bye.bytes = %v, want %d", bye["bytes"], total)
	}
	want := fmt.Sprintf("%016x", h.Sum64())
	if bye["fnv1a"] != want {
		t.Fatalf("checksum = %v, want %s", bye["fnv1a"], want)
	}
}

// TestRunnerEndToEnd (S1.2) drives the full nucleus path: frames through
// the Runner, events out, model name stamped on finals.
func TestRunnerEndToEnd(t *testing.T) {
	r := New(Config{
		Cmd:         adapterBin,
		Args:        []string{"--model", "echo-e2e"},
		Header:      testHeader(500),
		MaxRestarts: 3,
		Stderr:      io.Discard,
	})

	src := make(chan protocol.Frame, 8)
	sink := make(chan protocol.Event, 64)
	go func() {
		for i := 0; i < 6; i++ {
			src <- protocol.Frame{Index: i, Data: make([]byte, 3200), T0: float64(i), T1: float64(i) + 1}
		}
		close(src)
	}()

	stats, err := r.Run(context.Background(), src, sink)
	close(sink)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	finals := 0
	errors := 0
	for ev := range sink {
		switch ev.Type {
		case "final":
			finals++
			if ev.Model != "echo-e2e" {
				t.Fatalf("final model = %q, want echo-e2e", ev.Model)
			}
		case "error":
			errors++
		}
	}
	if finals != 6 {
		t.Fatalf("finals = %d, want 6", finals)
	}
	if errors != 0 {
		t.Fatalf("unexpected error events: %d", errors)
	}
	if stats.FramesSent != 6 || stats.Restarts != 0 || stats.LostFrames != 0 {
		t.Fatalf("stats = %+v", stats)
	}
}

// TestAdapterRestart (S1.4) crashes the adapter on purpose and verifies the
// restart policy: non-fatal adapter_crash events, restarts accounted, and the
// pipeline still completes.
func TestAdapterRestart(t *testing.T) {
	r := New(Config{
		Cmd:         adapterBin,
		Args:        []string{"--model", "echo-crash"},
		Env:         []string{"STT_ECHO_CRASH_AFTER=3"},
		Header:      testHeader(500),
		MaxRestarts: 3,
		Stderr:      io.Discard,
	})

	src := make(chan protocol.Frame, 8)
	sink := make(chan protocol.Event, 64)
	go func() {
		for i := 0; i < 8; i++ {
			src <- protocol.Frame{Index: i, Data: make([]byte, 320), T0: float64(i), T1: float64(i) + 1}
		}
		close(src)
	}()

	stats, err := r.Run(context.Background(), src, sink)
	close(sink)
	if err != nil {
		t.Fatalf("Run should complete despite crashes: %v", err)
	}

	crashes := 0
	finals := 0
	for ev := range sink {
		switch ev.Type {
		case "error":
			if ev.Code == "adapter_crash" && !ev.Fatal {
				crashes++
			} else {
				t.Fatalf("unexpected error event: %+v", ev)
			}
		case "final":
			finals++
		}
	}
	if crashes < 1 {
		t.Fatal("expected at least one adapter_crash event")
	}
	if stats.Restarts < 1 || stats.Restarts > 3 {
		t.Fatalf("restarts = %d, want 1..3", stats.Restarts)
	}
	if finals < 3 {
		t.Fatalf("finals = %d, want >= 3", finals)
	}
}
