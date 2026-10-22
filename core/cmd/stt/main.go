// Command stt is the nucleus: it streams PCM audio to a model adapter
// (stt-adapter/1) and writes text events to stdout (stt-events/1).
//
// Usage:
//
//	stt stream [--adapter CMD] [--model PATH] [--frame-ms N] < audio.pcm
//	stt once   [--adapter CMD] [--model PATH] file.wav
//	stt version
//
// Spec: docs/CONTRATOS.md.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"stt/internal/emit"
	"stt/internal/protocol"
	"stt/internal/runner"
	"stt/internal/segment"
	"stt/internal/wav"
)

const version = "0.1.0"

func usage() {
	fmt.Fprintln(os.Stderr, `usage: stt <stream|once|version> [options]

  stream   read raw PCM (s16le/16k/mono) from stdin, emit text events
  once     transcribe a WAV file (PCM s16le 16k mono), emit text events
  version  print version

Options (stream/once):
  --adapter CMD     model adapter command (default adapters/echo/stt-adapter-echo)
  --model PATH      model path passed to the adapter
  --frame-ms N      frame duration in ms (default 2000)
  --max-restarts N  adapter restart budget (default 3)`)
}

type commonFlags struct {
	adapter     string
	model       string
	frameMs     int
	rate        int
	channels    int
	maxRestarts int
}

func addCommon(fs *flag.FlagSet, c *commonFlags) {
	fs.StringVar(&c.adapter, "adapter", "adapters/echo/stt-adapter-echo", "model adapter command")
	fs.StringVar(&c.model, "model", "", "model path passed to the adapter")
	fs.IntVar(&c.frameMs, "frame-ms", 2000, "frame duration in ms")
	fs.IntVar(&c.rate, "rate", 16000, "sample rate of the input PCM")
	fs.IntVar(&c.channels, "channels", 1, "channels of the input PCM")
	fs.IntVar(&c.maxRestarts, "max-restarts", 3, "adapter restart budget")
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
	var c commonFlags
	fs := flag.NewFlagSet("stream", flag.ExitOnError)
	addCommon(fs, &c)
	_ = fs.Parse(args)
	return runPipeline(c, func(ctx context.Context) <-chan protocol.Frame {
		return segment.Frames(ctx, os.Stdin, c.rate, c.channels, c.frameMs)
	})
}

func cmdOnce(args []string) int {
	var c commonFlags
	fs := flag.NewFlagSet("once", flag.ExitOnError)
	addCommon(fs, &c)
	_ = fs.Parse(args)
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "stt once: exactly one WAV file required")
		return 2
	}
	path := fs.Arg(0)
	return runPipeline(c, func(ctx context.Context) <-chan protocol.Frame {
		r, err := wav.Open(path)
		if err != nil {
			fmt.Fprintf(os.Stderr, "stt once: %v\n", err)
			return nil
		}
		return segment.Frames(ctx, r, c.rate, c.channels, c.frameMs)
	})
}

// runPipeline wires source -> segment -> runner -> stdout (stt-events/1).
func runPipeline(c commonFlags, source func(context.Context) <-chan protocol.Frame) int {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	out := emit.New(os.Stdout)
	hdr := protocol.Header{
		Protocol: protocol.Version,
		Audio:    protocol.AudioFormat{Rate: c.rate, Channels: c.channels, Format: "s16le"},
		FrameMs:  c.frameMs,
	}
	_ = out.Event(protocol.Event{Type: "start", Audio: &hdr.Audio})

	args := []string{}
	if c.model != "" {
		args = append(args, "--model", c.model)
	}
	r := runner.New(runner.Config{
		Cmd:         c.adapter,
		Args:        args,
		Header:      hdr,
		MaxRestarts: c.maxRestarts,
	})

	sink := make(chan protocol.Event, 16)
	done := make(chan struct{})
	go func() {
		defer close(done)
		for ev := range sink {
			_ = out.Event(ev)
		}
	}()

	stats, err := r.Run(ctx, source(ctx), sink)
	close(sink)
	<-done

	if err != nil {
		_ = out.Event(protocol.Event{Type: "error", Code: "pipeline", Message: err.Error(), Fatal: true})
		return 1
	}
	_ = out.Event(protocol.Event{Type: "eof", Frames: stats.FramesSent, AudioS: stats.AudioS})
	return 0
}
