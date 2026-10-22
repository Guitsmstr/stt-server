// Package runner supervises model adapter subprocesses speaking
// stt-adapter/1 (see docs/CONTRATOS.md and docs/ARQUITECTURA.md §3).
package runner

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"sync/atomic"
	"time"

	"stt/internal/protocol"
)

// Config tunes the adapter subprocess lifecycle.
type Config struct {
	Cmd           string
	Args          []string
	Env           []string // extra environment entries (KEY=VALUE)
	Header        protocol.Header
	ReadyTimeout  time.Duration
	MaxRestarts   int
	RestartWindow time.Duration
	Stderr        io.Writer // adapter stderr sink (prefixed); defaults to os.Stderr
}

// Stats summarizes a run, for the eof event.
type Stats struct {
	FramesSent int
	AudioS     float64
	LostFrames int
	Restarts   int
	Model      string
	AdapterRSS int64 // adapter peak RSS from its "bye" event (kB), best-effort
}

// Runner executes one adapter at a time and restarts it on crash.
type Runner struct {
	cfg Config
}

// New returns a Runner with defaults applied.
func New(cfg Config) *Runner {
	if cfg.ReadyTimeout == 0 {
		cfg.ReadyTimeout = 30 * time.Second
	}
	if cfg.MaxRestarts == 0 {
		cfg.MaxRestarts = 3
	}
	if cfg.RestartWindow == 0 {
		cfg.RestartWindow = 60 * time.Second
	}
	if cfg.Stderr == nil {
		cfg.Stderr = os.Stderr
	}
	return &Runner{cfg: cfg}
}

// session is one adapter process lifetime.
type session struct {
	cmd     *exec.Cmd
	wr      *protocol.Writer
	stdin   io.WriteCloser
	events  chan protocol.Event
	readErr error
	done    chan struct{} // closed when the nucleus stops reading events
	once    sync.Once
}

func (r *Runner) start(ctx context.Context) (*session, error) {
	cmd := exec.CommandContext(ctx, r.cfg.Cmd, r.cfg.Args...)
	if len(r.cfg.Env) > 0 {
		cmd.Env = append(os.Environ(), r.cfg.Env...)
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start %s: %w", r.cfg.Cmd, err)
	}

	s := &session{
		cmd:    cmd,
		stdin:  stdin,
		events: make(chan protocol.Event, 8),
		done:   make(chan struct{}),
	}
	wr, err := protocol.NewWriter(stdin, r.cfg.Header)
	if err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return nil, err
	}
	s.wr = wr

	// Adapter stderr: forwarded with a prefix (logs are free-form).
	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := stderr.Read(buf)
			if n > 0 {
				fmt.Fprintf(r.cfg.Stderr, "[adapter] %s", buf[:n])
			}
			if err != nil {
				return
			}
		}
	}()

	// Adapter stdout: parsed as NDJSON events.
	go func() {
		defer close(s.events)
		rd := protocol.NewEventReader(stdout)
		for {
			ev, err := rd.Next()
			if err != nil {
				s.readErr = err
				return
			}
			select {
			case s.events <- ev:
			case <-s.done:
				return
			}
		}
	}()
	return s, nil
}

// fatalAdapterError marks an error reported by the adapter as fatal: the
// runner must not restart (e.g. unsupported audio, unloadable model).
type fatalAdapterError struct{ msg string }

func (e *fatalAdapterError) Error() string { return e.msg }

// waitReady blocks until the adapter announces itself (or fails).
func (s *session) waitReady(d time.Duration) (protocol.Event, error) {
	t := time.NewTimer(d)
	defer t.Stop()
	for {
		select {
		case ev, ok := <-s.events:
			if !ok {
				return protocol.Event{}, fmt.Errorf("adapter exited before ready: %v", s.readErr)
			}
			if ev.Type == "ready" {
				return ev, nil
			}
			if ev.Type == "error" && ev.Fatal {
				return protocol.Event{}, &fatalAdapterError{msg: "adapter fatal error before ready: " + ev.Message}
			}
		case <-t.C:
			return protocol.Event{}, fmt.Errorf("adapter ready timeout after %s", d)
		}
	}
}

func (s *session) writeFrame(payload []byte) error { return s.wr.WriteFrame(payload) }

func (s *session) closeStdin() { _ = s.stdin.Close() }

func (s *session) close() {
	s.once.Do(func() { close(s.done) })
	_ = s.stdin.Close()
	_ = s.cmd.Wait()
}

// Run streams frames from src to the adapter and forwards adapter events to
// sink. src must be closed when input ends. Run does not close sink.
// On adapter crash, in-flight frames may be lost (v1 policy, ARCHITECTURE §3).
func (r *Runner) Run(ctx context.Context, src <-chan protocol.Frame, sink chan<- protocol.Event) (Stats, error) {
	var stats Stats
	var mu sync.Mutex
	var restarts []time.Time

	send := func(ev protocol.Event) {
		select {
		case sink <- ev:
		case <-ctx.Done():
		}
	}

	for {
		sess, err := r.start(ctx)
		if err != nil {
			send(protocol.Event{Type: "error", Code: "adapter_start", Message: err.Error(), Fatal: true})
			return stats, fmt.Errorf("runner: %w", err)
		}

		ready, err := sess.waitReady(r.cfg.ReadyTimeout)
		if err != nil {
			sess.close()
			if ctx.Err() != nil {
				return stats, ctx.Err()
			}
			var fatal *fatalAdapterError
			if errors.As(err, &fatal) {
				send(protocol.Event{Type: "error", Code: "adapter_dead", Message: err.Error(), Fatal: true})
				return stats, fmt.Errorf("runner: %w", err)
			}
			if r.canRestart(&restarts) {
				mu.Lock()
				stats.Restarts++
				mu.Unlock()
				send(protocol.Event{Type: "error", Code: "adapter_restart", Message: err.Error(), Fatal: false})
				continue
			}
			send(protocol.Event{Type: "error", Code: "adapter_dead", Message: err.Error(), Fatal: true})
			return stats, fmt.Errorf("runner: %w", err)
		}
		mu.Lock()
		if stats.Model == "" {
			stats.Model = ready.Model
		}
		mu.Unlock()

		// Frame pump: reads from src until it closes (input EOF) or the
		// session dies. Frames stay queued in src for the next session.
		sessDone := make(chan struct{})
		var lost atomic.Int64
		writerDone := make(chan struct{})
		go func() {
			defer close(writerDone)
			for {
				select {
				case fr, ok := <-src:
					if !ok {
						sess.closeStdin() // adapter flushes pending finals, says bye
						return
					}
					if err := sess.writeFrame(fr.Data); err != nil {
						lost.Add(1)
						return
					}
					mu.Lock()
					stats.FramesSent++
					stats.AudioS = fr.T1
					mu.Unlock()
				case <-sessDone:
					return
				case <-ctx.Done():
					sess.closeStdin()
					return
				}
			}
		}()

		complete := false
		for ev := range sess.events {
			if ev.Type == "bye" {
				complete = true
				if ev.RSSKB > 0 {
					stats.AdapterRSS = ev.RSSKB
				}
				break
			}
			if ev.Type == "final" && ev.Model == "" {
				ev.Model = ready.Model
			}
			send(ev)
		}
		close(sessDone)
		<-writerDone
		sess.close()
		mu.Lock()
		stats.LostFrames += int(lost.Load())
		mu.Unlock()

		// Only "bye" means success (docs/CONTRATOS.md §2.4): EOF without it
		// is a crash, even at end of input. The restarted adapter then sees
		// empty input, says bye and completes cleanly.
		if complete || ctx.Err() != nil {
			return stats, nil
		}

		// Crash mid-stream: restart per policy (ARCHITECTURE §3).
		if r.canRestart(&restarts) {
			mu.Lock()
			stats.Restarts++
			mu.Unlock()
			send(protocol.Event{Type: "error", Code: "adapter_crash", Message: "adapter exited unexpectedly; restarting", Fatal: false})
			continue
		}
		send(protocol.Event{Type: "error", Code: "adapter_dead", Message: "adapter crashed and restart budget exhausted", Fatal: true})
		return stats, fmt.Errorf("runner: adapter crashed and restart budget exhausted")
	}
}

// canRestart applies the restart budget: at most MaxRestarts within RestartWindow.
func (r *Runner) canRestart(rs *[]time.Time) bool {
	now := time.Now()
	cut := now.Add(-r.cfg.RestartWindow)
	kept := (*rs)[:0]
	for _, t := range *rs {
		if t.After(cut) {
			kept = append(kept, t)
		}
	}
	*rs = kept
	if len(*rs) >= r.cfg.MaxRestarts {
		return false
	}
	*rs = append(*rs, now)
	return true
}
