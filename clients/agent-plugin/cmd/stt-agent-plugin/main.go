// Command stt-agent-plugin is the reference stt-remote/1 client CLI
// (Spec C, S6.5): it prints every surfaced event as its original NDJSON
// line on stdout, one per line, and diagnostics on stderr. The reusable
// implementation lives in package stt-client (plugin.go).
//
// Exit codes: 0 clean end (eof with --once, SIGINT/SIGTERM), 2 usage or
// authentication error (HTTP 401: a wrong token is not retried), 1 any
// other failure.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	sttclient "stt-client"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("stt-agent-plugin", flag.ContinueOnError)
	fs.SetOutput(stderr)
	feedURL := fs.String("url", "ws://127.0.0.1:4719/v1/feed", "sttd feed `url` (ws://host:port/v1/feed)")
	token := fs.String("token", "", "bearer `token` (required; sttd --print-token shows it)")
	partials := fs.Bool("partials", false, "also surface partial events (default: finals only)")
	once := fs.Bool("once", false, "exit after the first eof instead of reconnecting")
	queryToken := fs.Bool("query-token", false, "send the token as ?token= instead of the Authorization header")
	quiet := fs.Bool("quiet", false, "suppress info diagnostics on stderr")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}
	if *token == "" {
		fmt.Fprintln(stderr, "stt-agent-plugin: --token is required")
		return 2
	}

	// SIGINT/SIGTERM end the run cleanly: close the WS, print the summary.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	c := sttclient.New(*feedURL, *token,
		sttclient.WithPartials(*partials),
		sttclient.WithOnce(*once),
		sttclient.WithQueryToken(*queryToken),
		sttclient.WithQuiet(*quiet),
	)
	err := c.Run(ctx, func(ev sttclient.Event) {
		fmt.Fprintln(stdout, ev.Raw) // surfaced events: verbatim NDJSON
	})

	st := c.Stats()
	fmt.Fprintf(stderr, "stt-agent-plugin: %d events surfaced, %d duplicates_suppressed, %d reconnects\n",
		st.Surfaced, st.DuplicatesSuppressed, st.Reconnects)
	if err == nil || errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return 0
	}
	var ae *sttclient.AuthError
	if errors.As(err, &ae) {
		fmt.Fprintln(stderr, ae)
		return 2
	}
	fmt.Fprintln(stderr, "stt-agent-plugin:", err)
	return 1
}
