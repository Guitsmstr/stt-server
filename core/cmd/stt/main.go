// Command stt is the nucleus: it streams PCM audio to a model adapter
// (stt-adapter/1) and writes text events to stdout (stt-events/1).
//
// Usage:
//
//	stt stream [--config FILE] [--adapter CMD] [--model PATH] [flags] < audio.pcm
//	stt once   [--config FILE] [--adapter CMD] [--model PATH] [flags] file.wav
//	stt version
//
// Configuration is read from config/stt.toml (or --config FILE); flags
// override file values. Spec: docs/CONTRATOS.md; segmentation:
// docs/ARQUITECTURA.md §4 (decision D9).
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"stt/internal/config"
	"stt/internal/emit"
	"stt/internal/fanout"
	"stt/internal/protocol"
	"stt/internal/runner"
	"stt/internal/segment"
	"stt/internal/wav"
)

const version = "0.4.0"

const defaultConfigPath = "config/stt.toml"

func usage() {
	fmt.Fprintln(os.Stderr, `usage: stt <stream|once|version> [options]

  stream   read raw PCM (s16le/16k/mono) from stdin, emit text events
  once     transcribe a WAV file (PCM s16le 16k mono), emit text events
  version  print version

Options (stream/once; defaults come from config/stt.toml):
  --config FILE         config file (default config/stt.toml; missing = defaults)
  --adapter CMD         model adapter command
  --model PATH          model path passed to the adapter
  --frame-ms N          target segment duration in ms
  --min-segment-ms N    minimum audio before a pause may end a segment
  --vad BOOL            energy-aware cuts and silence skip (default true; --vad=false = fixed frames)
  --vad-threshold X     speech RMS threshold (samples normalized to [-1,1])
  --partials            forward adapter "partial" events to stdout
  --out ADDR            fan out the same NDJSON to clients: tcp://host:port or unix:///path
  --max-restarts N      adapter restart budget`)
}

// resolved holds the final configuration after file + flags.
type resolved struct {
	cfg      config.Config
	fs       *flag.FlagSet
	adapter  string
	model    string
	frameMs  int
	rate     int
	channels int
	// flag targets (values only meaningful if the flag was set)
	adapterF      string
	modelF        string
	frameMsF      int
	minSegmentMsF int
	rateF         int
	channelsF     int
	maxRestartsF  int
	vadF          bool
	thresholdF    float64
	partialsF     bool
	outF          string
}

// parseOptions loads the config (honoring an early --config flag) and parses
// the remaining flags on top of it.
func parseOptions(name string, args []string) (resolved, error) {
	var r resolved

	// Pre-scan for --config: it changes the defaults of every other flag.
	path := ""
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--config" || a == "-config":
			if i+1 >= len(args) {
				return r, fmt.Errorf("--config requires a file path")
			}
			path = args[i+1]
			i++
		case strings.HasPrefix(a, "--config="):
			path = strings.TrimPrefix(a, "--config=")
		case strings.HasPrefix(a, "-config="):
			path = strings.TrimPrefix(a, "-config=")
		}
	}
	explicit := path != ""
	if !explicit {
		path = defaultConfigPath
	}
	cfg, err := config.Load(path, explicit)
	if err != nil {
		return r, err
	}
	r.cfg = cfg

	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	r.fs = fs
	configPath := path // already resolved by the pre-scan above; registered for --help
	fs.StringVar(&configPath, "config", path, "config file (default config/stt.toml)")
	fs.StringVar(&r.adapterF, "adapter", cfg.Adapter.Cmd, "model adapter command")
	fs.StringVar(&r.modelF, "model", "", "model path passed to the adapter")
	fs.IntVar(&r.frameMsF, "frame-ms", cfg.Segment.FrameMs, "target segment duration in ms")
	fs.IntVar(&r.minSegmentMsF, "min-segment-ms", cfg.Segment.MinSegmentMs, "minimum audio before a pause may end a segment")
	fs.IntVar(&r.rateF, "rate", cfg.Audio.Rate, "sample rate of the input PCM")
	fs.IntVar(&r.channelsF, "channels", cfg.Audio.Channels, "channels of the input PCM")
	fs.IntVar(&r.maxRestartsF, "max-restarts", cfg.Runner.MaxRestarts, "adapter restart budget")
	fs.BoolVar(&r.vadF, "vad", cfg.Segment.VAD, "energy-aware cuts and silence skip")
	fs.Float64Var(&r.thresholdF, "vad-threshold", cfg.Segment.VADRMS, "speech RMS threshold")
	fs.BoolVar(&r.partialsF, "partials", cfg.Output.Partials, "forward adapter partial events")
	fs.StringVar(&r.outF, "out", cfg.Output.Listen, "fan-out listener (tcp://host:port or unix:///path)")
	if err := fs.Parse(args); err != nil {
		return r, err
	}

	// Apply explicitly set flags over the config values (flag package already
	// seeded the defaults; Visit tells us which ones the user overrode).
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })
	r.cfg.Segment.VAD = r.vadF
	r.cfg.Segment.VADRMS = r.thresholdF
	r.cfg.Output.Partials = r.partialsF
	r.cfg.Output.Listen = r.outF
	r.adapter = r.adapterF
	r.model = r.modelF
	r.frameMs = r.frameMsF
	r.rate = r.rateF
	r.channels = r.channelsF
	if set["adapter"] {
		r.cfg.Adapter.Cmd = r.adapterF
	}
	if set["model"] {
		r.cfg.Adapter.Args = withModelArg(r.cfg.Adapter.Args, r.modelF)
	}
	if set["frame-ms"] {
		r.cfg.Segment.FrameMs = r.frameMsF
	}
	if set["min-segment-ms"] {
		r.cfg.Segment.MinSegmentMs = r.minSegmentMsF
	}
	if set["rate"] {
		r.cfg.Audio.Rate = r.rateF
	}
	if set["channels"] {
		r.cfg.Audio.Channels = r.channelsF
	}
	if set["max-restarts"] {
		r.cfg.Runner.MaxRestarts = r.maxRestartsF
	}
	return r, nil
}

// withModelArg replaces any --model pair in args with the new value (or
// appends it when the adapter args had none).
func withModelArg(args []string, model string) []string {
	out := args[:0:0]
	for i := 0; i < len(args); i++ {
		if args[i] == "--model" && i+1 < len(args) {
			i++ // drop the old value
			continue
		}
		out = append(out, args[i])
	}
	if model != "" {
		out = append(out, "--model", model)
	}
	return out
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "stream":
		os.Exit(cmdStream(os.Args[2:]))
	case "once":
		os.Exit(cmdOnce(os.Args[2:]))
	case "version":
		fmt.Printf("stt %s (%s, stt-events/1)\n", version, protocol.Version)
	default:
		usage()
		os.Exit(2)
	}
}

func cmdStream(args []string) int {
	o, err := parseOptions("stream", args)
	if err != nil {
		fmt.Fprintf(os.Stderr, "stt stream: %v\n", err)
		return 2
	}
	return runPipeline(o, func(ctx context.Context) <-chan segment.Segment {
		return segment.Segments(ctx, os.Stdin, segmentOptions(o))
	})
}

func cmdOnce(args []string) int {
	o, err := parseOptions("once", args)
	if err != nil {
		fmt.Fprintf(os.Stderr, "stt once: %v\n", err)
		return 2
	}
	if o.fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "stt once: exactly one WAV file required")
		return 2
	}
	path := o.fs.Arg(0)
	f, err := wav.Open(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "stt once: %v\n", err)
		return 2
	}
	return runPipeline(o, func(ctx context.Context) <-chan segment.Segment {
		return segment.Segments(ctx, f, segmentOptions(o))
	})
}

func segmentOptions(o resolved) segment.Options {
	return segment.Options{
		Rate:         o.rate,
		Channels:     o.channels,
		FrameMs:      o.frameMs,
		HopMs:        o.cfg.Segment.HopMs,
		Threshold:    o.cfg.Segment.VADRMS,
		MinSpeechMs:  o.cfg.Segment.MinSpeechMs,
		MinSegmentMs: o.cfg.Segment.MinSegmentMs,
		MaxStretchMs: o.cfg.Segment.MaxStretchMs,
		VAD:          o.cfg.Segment.VAD,
	}
}

// timeline records the stream-true [t0,t1] of every segment sent to the
// adapter (keyed by the adapter's frame index: the k-th frame it received is
// the k-th segment the nucleus sent). The nucleus re-stamps final/partial
// events with these values because with VAD skips the adapter's own t0/t1
// (computed from the bytes it received) lag behind the real stream time.
// Authority of stt-events/1 t0/t1: the nucleus (docs/CONTRATOS.md §3).
type timeline struct {
	mu sync.Mutex
	ts []struct{ t0, t1 float64 }
}

func (tl *timeline) add(t0, t1 float64) {
	tl.mu.Lock()
	tl.ts = append(tl.ts, struct{ t0, t1 float64 }{t0, t1})
	tl.mu.Unlock()
}

func (tl *timeline) stamp(ev *protocol.Event) {
	if ev.Type != "final" && ev.Type != "partial" {
		return
	}
	tl.mu.Lock()
	defer tl.mu.Unlock()
	if ev.Frame >= 0 && ev.Frame < len(tl.ts) {
		ev.T0, ev.T1 = tl.ts[ev.Frame].t0, tl.ts[ev.Frame].t1
	}
}

// runPipeline wires source -> segment (VAD) -> runner -> stdout (stt-events/1).
func runPipeline(o resolved, source func(context.Context) <-chan segment.Segment) int {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Optional remote fan-out (D13): the same stt-events/1 lines that go to
	// stdout are broadcast to every connected client. Listen before the start
	// event so a client that connects immediately never misses it.
	var eventSink io.Writer = os.Stdout
	if o.cfg.Output.Listen != "" {
		hub, err := fanout.Listen(o.cfg.Output.Listen)
		if err != nil {
			_ = emit.New(os.Stdout).Event(protocol.Event{
				Type: "error", Code: "output_listen", Message: err.Error(), Fatal: true,
			})
			return 1
		}
		defer hub.Close()
		// Hub first: a slow stdout consumer must not add latency to sockets.
		eventSink = io.MultiWriter(hub, os.Stdout)
	}
	out := emit.New(eventSink)
	hdr := protocol.Header{
		Protocol: protocol.Version,
		Audio:    protocol.AudioFormat{Rate: o.rate, Channels: o.channels, Format: "s16le"},
		FrameMs:  o.frameMs,
	}
	_ = out.Event(protocol.Event{Type: "start", Audio: &hdr.Audio})

	r := runner.New(runner.Config{
		Cmd:           o.cfg.Adapter.Cmd,
		Args:          o.cfg.Adapter.Args,
		Header:        hdr,
		MaxRestarts:   o.cfg.Runner.MaxRestarts,
		RestartWindow: time.Duration(o.cfg.Runner.RestartWindowS) * time.Second,
	})

	// Segment pump: drop non-speech segments (VAD silence skip), record the
	// stream-true time of every sent segment, and count skipped audio.
	frames := make(chan protocol.Frame, 8)
	var tl timeline
	var skippedS, totalS float64
	go func() {
		defer close(frames)
		for seg := range source(ctx) {
			if seg.T1 > totalS {
				totalS = seg.T1
			}
			if seg.Speech {
				tl.add(seg.T0, seg.T1)
				frames <- seg.Frame
			} else {
				skippedS += seg.T1 - seg.T0
			}
		}
	}()

	sink := make(chan protocol.Event, 16)
	done := make(chan struct{})
	go func() {
		defer close(done)
		for ev := range sink {
			if ev.Type == "partial" && !o.cfg.Output.Partials {
				continue // [output] partials = false (default)
			}
			tl.stamp(&ev)
			_ = out.Event(ev)
		}
	}()

	stats, err := r.Run(ctx, frames, sink)
	close(sink)
	<-done

	if err != nil {
		_ = out.Event(protocol.Event{Type: "error", Code: "pipeline", Message: err.Error(), Fatal: true})
		return 1
	}
	_ = out.Event(protocol.Event{
		Type: "eof", Frames: stats.FramesSent, AudioS: totalS,
		SkippedS: skippedS, RSSKB: stats.AdapterRSS,
	})
	return 0
}
