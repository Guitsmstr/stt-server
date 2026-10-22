// Package protocol implements the stt-adapter/1 wire protocol:
// the nucleus talks to model adapter subprocesses through it.
// Spec: docs/CONTRATOS.md (contract version stt-adapter/1).
package protocol

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
)

// Version is the protocol version implemented by this package.
const Version = "stt-adapter/1"

// AudioFormat describes the PCM stream carried by the protocol.
type AudioFormat struct {
	Rate     int    `json:"rate"`
	Channels int    `json:"channels"`
	Format   string `json:"format"` // v1: always "s16le"
}

// Header is the single JSON line sent nucleus -> adapter before any frame.
type Header struct {
	Protocol string      `json:"protocol"`
	Audio    AudioFormat `json:"audio"`
	FrameMs  int         `json:"frame_ms"`
}

// Event is a stt-adapter/1 event (adapter -> nucleus) and the base of
// stt-events/1 events (nucleus -> stdout). Unknown JSON fields are ignored.
type Event struct {
	Type         string       `json:"type"`
	Protocol     string       `json:"protocol,omitempty"`
	Name         string       `json:"name,omitempty"`
	Model        string       `json:"model,omitempty"`
	Text         string       `json:"text,omitempty"`
	Frame        int          `json:"frame,omitempty"`
	T0           float64      `json:"t0,omitempty"`
	T1           float64      `json:"t1,omitempty"`
	RTF          float64      `json:"rtf,omitempty"`
	Code         string       `json:"code,omitempty"`
	Message      string       `json:"message,omitempty"`
	Fatal        bool         `json:"fatal,omitempty"`
	Capabilities []string     `json:"capabilities,omitempty"`
	Audio        *AudioFormat `json:"audio,omitempty"`
	Frames       int          `json:"frames,omitempty"`
	AudioS       float64      `json:"audio_s,omitempty"`
	RSSKB        int64        `json:"rss_kb,omitempty"`
}

// Frame is one unit of PCM audio sent nucleus -> adapter.
type Frame struct {
	Index int
	Data  []byte
	T0    float64 // seconds of audio before this frame
	T1    float64 // seconds of audio after this frame
}

// Writer sends the header line and length-prefixed PCM frames
// (uint32 LE length + payload). Not safe for concurrent use.
type Writer struct {
	w io.Writer
}

// NewWriter writes the header line to w and returns a frame writer.
func NewWriter(w io.Writer, h Header) (*Writer, error) {
	b, err := json.Marshal(h)
	if err != nil {
		return nil, fmt.Errorf("protocol: marshal header: %w", err)
	}
	b = append(b, '\n')
	if _, err := w.Write(b); err != nil {
		return nil, fmt.Errorf("protocol: write header: %w", err)
	}
	return &Writer{w: w}, nil
}

// WriteFrame sends one PCM frame with the uint32 LE length prefix.
func (s *Writer) WriteFrame(payload []byte) error {
	var lenbuf [4]byte
	binary.LittleEndian.PutUint32(lenbuf[:], uint32(len(payload)))
	if _, err := s.w.Write(lenbuf[:]); err != nil {
		return err
	}
	if len(payload) == 0 {
		return nil
	}
	_, err := s.w.Write(payload)
	return err
}

// EventReader parses NDJSON event lines (adapter -> nucleus).
type EventReader struct {
	s *bufio.Scanner
}

// NewEventReader wraps r; lines up to 1 MiB are supported.
func NewEventReader(r io.Reader) *EventReader {
	s := bufio.NewScanner(r)
	s.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	return &EventReader{s: s}
}

// NextRaw returns the next raw event line (without trailing newline).
func (e *EventReader) NextRaw() ([]byte, error) {
	if !e.s.Scan() {
		if err := e.s.Err(); err != nil {
			return nil, err
		}
		return nil, io.EOF
	}
	ln := e.s.Bytes()
	out := make([]byte, len(ln))
	copy(out, ln)
	return out, nil
}

// Next returns the next parsed event. Returns io.EOF when the stream ends.
func (e *EventReader) Next() (Event, error) {
	b, err := e.NextRaw()
	if err != nil {
		return Event{}, err
	}
	var ev Event
	if err := json.Unmarshal(b, &ev); err != nil {
		return Event{}, fmt.Errorf("protocol: invalid event line: %w", err)
	}
	return ev, nil
}
