package protocol

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"testing"
)

// TestFrameFraming verifies the wire format of stt-adapter/1:
// one JSON header line, then uint32 LE length + payload per frame.
func TestFrameFraming(t *testing.T) {
	var buf bytes.Buffer
	h := Header{
		Protocol: Version,
		Audio:    AudioFormat{Rate: 16000, Channels: 1, Format: "s16le"},
		FrameMs:  2000,
		VAD:      true,
	}
	w, err := NewWriter(&buf, h)
	if err != nil {
		t.Fatal(err)
	}

	frame1 := bytes.Repeat([]byte{0xAB}, 64000) // 2 s @ 16 kHz mono s16
	frame2 := []byte{1, 2, 3}
	if err := w.WriteFrame(frame1); err != nil {
		t.Fatal(err)
	}
	if err := w.WriteFrame(frame2); err != nil {
		t.Fatal(err)
	}

	data := buf.Bytes()
	nl := bytes.IndexByte(data, '\n')
	if nl < 0 {
		t.Fatal("missing header line")
	}
	var got Header
	if err := json.Unmarshal(data[:nl], &got); err != nil {
		t.Fatalf("header is not valid JSON: %v", err)
	}
	if got.Protocol != Version || got.Audio.Rate != 16000 || got.Audio.Channels != 1 ||
		got.Audio.Format != "s16le" || got.FrameMs != 2000 || !got.VAD {
		t.Fatalf("header mismatch: %+v", got)
	}

	rest := data[nl+1:]
	check := func(payload []byte) {
		t.Helper()
		if len(rest) < 4 {
			t.Fatal("missing length prefix")
		}
		n := binary.LittleEndian.Uint32(rest[:4])
		if int(n) != len(payload) {
			t.Fatalf("length prefix = %d, want %d", n, len(payload))
		}
		rest = rest[4:]
		if !bytes.Equal(rest[:n], payload) {
			t.Fatal("payload corrupted")
		}
		rest = rest[n:]
	}
	check(frame1)
	check(frame2)
	if len(rest) != 0 {
		t.Fatalf("trailing bytes after last frame: %d", len(rest))
	}
}
