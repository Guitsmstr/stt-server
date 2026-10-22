// Package emit writes stt-events/1 NDJSON to the consumer (stdout).
package emit

import (
	"encoding/json"
	"io"
	"strings"
	"sync"

	"stt/internal/protocol"
)

// Writer serializes events as NDJSON lines. Safe for concurrent use.
type Writer struct {
	mu sync.Mutex
	w  io.Writer
}

// New wraps w as an NDJSON event writer.
func New(w io.Writer) *Writer { return &Writer{w: w} }

// finalEvent is the wire shape of stt-events/1 "final" events. It keeps
// "text":"" for empty transcriptions (protocol.Event uses omitempty for the
// rest of the event types, where an empty text field would be noise).
type finalEvent struct {
	Type  string  `json:"type"`
	Text  string  `json:"text"`
	Frame int     `json:"frame,omitempty"`
	T0    float64 `json:"t0,omitempty"`
	T1    float64 `json:"t1,omitempty"`
	RTF   float64 `json:"rtf,omitempty"`
	Model string  `json:"model,omitempty"`
}

// Event writes one event line. Text is sanitized: no embedded newlines
// (stt-events/1 rule, docs/CONTRATOS.md §3).
func (e *Writer) Event(ev protocol.Event) error {
	if ev.Text != "" {
		ev.Text = strings.NewReplacer("\r", " ", "\n", " ").Replace(ev.Text)
	}
	var b []byte
	var err error
	if ev.Type == "final" {
		b, err = json.Marshal(finalEvent{
			Type: ev.Type, Text: ev.Text, Frame: ev.Frame, T0: ev.T0, T1: ev.T1,
			RTF: ev.RTF, Model: ev.Model,
		})
	} else {
		b, err = json.Marshal(ev)
	}
	if err != nil {
		return err
	}
	b = append(b, '\n')
	e.mu.Lock()
	defer e.mu.Unlock()
	_, err = e.w.Write(b)
	return err
}
