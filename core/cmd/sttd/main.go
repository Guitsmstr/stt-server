// Command sttd is the remote text delivery service (stt-remote/1): it
// supervises one session pipeline (scripts/stt-mic.sh by default), reads the
// stt-events/1 NDJSON from its stdout and republishes every event verbatim
// to receive-only WebSocket clients. Spec: docs/CONTRATOS.md §9.
//
// Usage:
//
//	sttd [--config FILE] [--listen ADDR] [--token TOKEN] [--engine NAME]
//	     [--pipeline CMD] [--max-clients N] [--partials] [--print-token]
//	     [--version]
//
// Configuration is read from config/stt.toml (or --config FILE); flags
// override file values. The default bind is loopback only; listening on the
// LAN requires an explicit --listen 0.0.0.0:4719 (decision D18).
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/coder/websocket"

	"stt/internal/config"
	"stt/internal/server"
)

const version = "0.1.0"

const (
	defaultConfigPath = "config/stt.toml"
	defaultPipeline   = "scripts/stt-mic.sh"
)

func usage() {
	fmt.Fprintln(os.Stderr, `usage: sttd [options]

  --config FILE     config file (default config/stt.toml; missing = defaults)
  --listen ADDR     bind address (default 127.0.0.1:4719; LAN requires 0.0.0.0)
  --token TOKEN     inline bearer token (overrides the token file)
  --token-file PATH token file (default var/etc/stt-token; generated if missing)
  --max-clients N   maximum simultaneous clients (default 8)
  --engine NAME     engine descriptor; default pipeline becomes
                    "scripts/stt-mic.sh --engine NAME"
  --pipeline CMD    session command, verbatim (default scripts/stt-mic.sh)
  --partials        hello.session.partials descriptor
  --print-token     print the resolved token and exit
  --version         print "sttd 0.1.0 (stt-remote/1)" and exit`)
}

// resolved holds the final configuration after file + flags.
type resolved struct {
	cfg        config.Config
	fs         *flag.FlagSet
	listenF    string
	tokenF     string
	tokenFileF string
	maxClients int
	engineF    string
	pipelineF  string
	partialsF  bool
	printToken bool
	versionF   bool
}

// parseOptions loads the config (honoring an early --config flag) and parses
// the remaining flags on top of it, mirroring cmd/stt.
func parseOptions(args []string) (resolved, error) {
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

	fs := flag.NewFlagSet("sttd", flag.ContinueOnError)
	r.fs = fs
	configPath := path // already resolved by the pre-scan; registered for --help
	fs.StringVar(&configPath, "config", path, "config file")
	fs.StringVar(&r.listenF, "listen", cfg.Server.Listen, "bind address")
	fs.StringVar(&r.tokenF, "token", cfg.Server.Token, "inline bearer token")
	fs.StringVar(&r.tokenFileF, "token-file", cfg.Server.TokenFile, "token file path")
	fs.IntVar(&r.maxClients, "max-clients", cfg.Server.MaxClients, "maximum simultaneous clients")
	fs.StringVar(&r.engineF, "engine", cfg.Server.Engine, "engine descriptor")
	fs.StringVar(&r.pipelineF, "pipeline", cfg.Server.Pipeline, "session command, verbatim")
	fs.BoolVar(&r.partialsF, "partials", cfg.Server.Partials, "hello.session.partials descriptor")
	fs.BoolVar(&r.printToken, "print-token", false, "print the resolved token and exit")
	fs.BoolVar(&r.versionF, "version", false, "print version and exit")
	if err := fs.Parse(args); err != nil {
		return r, err
	}
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })
	r.partialsF = r.partialsF || set["partials"]
	return r, nil
}

// engine returns the hello.session.engine descriptor: the explicit engine
// (--engine / [server] engine) or, by default, the basename of the adapter
// command from the config.
func (r resolved) engine() string {
	if r.engineF != "" {
		return r.engineF
	}
	return filepath.Base(r.cfg.Adapter.Cmd)
}

// partials resolves the hello.session.partials descriptor: explicit flag or
// [server] partials, defaulting to true for sherpa engines (they stream
// word-by-word partials natively).
func (r resolved) partials() bool {
	return r.partialsF || strings.HasPrefix(r.engineF, "sherpa")
}

// pipelineCommand resolves the session command: --pipeline / [server]
// pipeline verbatim, else scripts/stt-mic.sh (+ --engine NAME when an
// explicit engine is set).
func (r resolved) pipelineCommand() string {
	if r.pipelineF != "" {
		return r.pipelineF
	}
	if r.engineF != "" {
		return defaultPipeline + " --engine " + r.engineF
	}
	return defaultPipeline
}

func main() {
	o, err := parseOptions(os.Args[1:])
	if err != nil {
		fmt.Fprintf(os.Stderr, "sttd: %v\n", err)
		os.Exit(2)
	}
	if o.versionF {
		fmt.Printf("sttd %s (%s)\n", version, server.ProtocolVersion)
		return
	}

	// Token: --token / [server] token first, then the token file
	// (generated on first run). The token itself is never logged.
	token, source, err := server.LoadToken(server.TokenConfig{
		Token:     o.tokenF,
		TokenFile: o.tokenFileF,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "sttd: %v\n", err)
		os.Exit(1)
	}
	if o.printToken {
		fmt.Println(token)
		return
	}

	hub, err := server.New(server.Options{
		Listen:     o.listenF,
		Token:      token,
		MaxClients: o.maxClients,
		Engine:     o.engine(),
		Partials:   o.partials(),
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "sttd: %v\n", err)
		os.Exit(1)
	}
	hub.Serve()
	fmt.Fprintf(os.Stderr, "sttd: listening on ws://%s/v1/feed (token: %s)\n", hub.Addr(), source)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Event mirror (opt-in): subscribe to the hub like any other client and
	// write every published event to stdout (see mirrorStdout).
	if os.Getenv("STTD_MIRROR_STDOUT") != "" {
		mirrorStdout(ctx, hub.Addr(), token)
	}

	pipeline := server.NewPipeline(server.PipelineOptions{
		Command:       o.pipelineCommand(),
		Hub:           hub,
		MaxRestarts:   o.cfg.Runner.MaxRestarts,
		RestartWindow: time.Duration(o.cfg.Runner.RestartWindowS) * time.Second,
		Stderr:        os.Stderr,
	})
	plDone := make(chan error, 1)
	go func() { plDone <- pipeline.Run(ctx) }()

	select {
	case err := <-plDone:
		if err != nil {
			// Fatal pipeline death: clients got the error and were closed
			// with 1011; the server stays up until a signal.
			fmt.Fprintf(os.Stderr, "sttd: %v (server still listening; interrupt to exit)\n", err)
		}
		<-ctx.Done()
	case <-ctx.Done():
	}
	stop()

	// Stop the pipeline (SIGINT forwarded, hard kill after 5 s), then close
	// the clients with 1001 and exit cleanly.
	select {
	case <-plDone:
	case <-time.After(15 * time.Second):
		fmt.Fprintln(os.Stderr, "sttd: pipeline did not stop in time; exiting anyway")
	}
	closeCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := hub.Close(closeCtx); err != nil {
		fmt.Fprintf(os.Stderr, "sttd: %v\n", err)
		os.Exit(1)
	}
}

// mirrorStdout, when enabled by the caller (main), subscribes to the hub
// like any other receive-only client and copies every event it receives to
// sttd's own stdout, one raw NDJSON line per message (everything after the
// hello framing, which is hub protocol, not a pipeline event). The Stage 6
// harness (tests/run-stage6-tests.sh) diffs this mirror against what the
// external WS clients receive: same events, same order. It is opt-in via
// STTD_MIRROR_STDOUT because it consumes one max_clients slot; without it
// sttd writes nothing to stdout.
func mirrorStdout(ctx context.Context, addr, token string) {
	go func() {
		dctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		conn, _, err := websocket.Dial(dctx, "ws://"+addr+"/v1/feed",
			&websocket.DialOptions{
				HTTPHeader: http.Header{"Authorization": []string{"Bearer " + token}},
			})
		cancel()
		if err != nil {
			fmt.Fprintf(os.Stderr, "sttd: stdout mirror off: %v\n", err)
			return
		}
		defer conn.CloseNow()
		first := true
		for {
			_, r, err := conn.Reader(ctx)
			if err != nil {
				return // shutdown (1001) or hub closed
			}
			line, err := io.ReadAll(r)
			if err != nil {
				return
			}
			if first {
				first = false // hello
				continue
			}
			if _, err := os.Stdout.Write(append(line, '\n')); err != nil {
				return
			}
		}
	}()
}
