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

// Event writes one event line. Text is sanitized: no embedded newlines
// (stt-events/1 rule, docs/CONTRATOS.md §3).
func (e *Writer) Event(ev protocol.Event) error {
	if ev.Text != "" {
		ev.Text = strings.NewReplacer("\r", " ", "\n", " ").Replace(ev.Text)
	}
	b, err := json.Marshal(ev)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	e.mu.Lock()
	defer e.mu.Unlock()
	_, err = e.w.Write(b)
	return err
}
