// Package config loads config/stt.toml (a small TOML subset) on top of
// built-in defaults. CLI flags override file values (see cmd/stt).
//
// Supported syntax: [section] headers, key = value with int / float / bool /
// "string" / ["string", ...], full-line and trailing # comments. Unknown
// sections or keys are an error (typo safety). Spec: docs/ARQUITECTURA.md §5.
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Audio is the PCM contract of the pipeline (docs/CONTRATOS.md §1).
type Audio struct {
	Rate     int
	Channels int
	Format   string
}

// Segment tunes the nucleus segmenter (docs/ARQUITECTURA.md §4, decision D9).
type Segment struct {
	FrameMs      int     // target segment cadence
	VAD          bool    // energy-aware cuts + silence skip (false = fixed frames)
	VADRMS       float64 // speech threshold: RMS of samples normalized to [-1,1]
	HopMs        int     // VAD analysis hop
	MinSpeechMs  int     // segments with less speech than this are dropped
	MinSegmentMs int     // minimum audio before a pause may end a segment
	MaxStretchMs int     // how far past FrameMs a segment may stretch to find a dip
}

// Adapter is the model adapter subprocess command.
type Adapter struct {
	Cmd  string
	Args []string
}

// Runner tunes adapter supervision (restart policy).
type Runner struct {
	MaxRestarts    int
	RestartWindowS int
}

// Output tunes stt-events/1 emission.
type Output struct {
	Partials bool // forward adapter "partial" events to stdout
}

// Config is the resolved configuration.
type Config struct {
	Audio   Audio
	Segment Segment
	Adapter Adapter
	Runner  Runner
	Output  Output
}

// Default returns the built-in configuration (equal to config/stt.toml).
func Default() Config {
	return Config{
		Audio: Audio{Rate: 16000, Channels: 1, Format: "s16le"},
		Segment: Segment{
			FrameMs: 5000, VAD: true, VADRMS: 0.01, HopMs: 30,
			MinSpeechMs: 0, MinSegmentMs: 3000, MaxStretchMs: 300,
		},
		Adapter: Adapter{Cmd: "adapters/echo/stt-adapter-echo"},
		Runner:  Runner{MaxRestarts: 3, RestartWindowS: 60},
		Output:  Output{Partials: false},
	}
}

// Load parses path on top of Default(). A missing file is an error only when
// required is true (otherwise defaults apply silently).
func Load(path string, required bool) (Config, error) {
	c := Default()
	if path == "" {
		return c, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) && !required {
			return c, nil
		}
		return c, err
	}
	if err := parse(string(data), &c); err != nil {
		return c, fmt.Errorf("%s: %w", path, err)
	}
	return c, nil
}

func parse(src string, c *Config) error {
	section := ""
	for i, raw := range strings.Split(src, "\n") {
		line := strings.TrimSpace(stripComment(raw))
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "[") {
			if !strings.HasSuffix(line, "]") {
				return fmt.Errorf("line %d: malformed section %q", i+1, line)
			}
			section = strings.TrimSpace(line[1 : len(line)-1])
			continue
		}
		eq := strings.Index(line, "=")
		if eq < 0 {
			return fmt.Errorf("line %d: expected key = value, got %q", i+1, line)
		}
		key, val := strings.TrimSpace(line[:eq]), strings.TrimSpace(line[eq+1:])
		if err := assign(c, section, key, val); err != nil {
			return fmt.Errorf("line %d: %w", i+1, err)
		}
	}
	return nil
}

// stripComment removes a # comment outside of quoted strings.
func stripComment(s string) string {
	inQuote := false
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '"':
			inQuote = !inQuote
		case '#':
			if !inQuote {
				return s[:i]
			}
		}
	}
	return s
}

func assign(c *Config, section, key, val string) error {
	switch section + "." + key {
	case "audio.rate":
		return setInt(val, &c.Audio.Rate)
	case "audio.channels":
		return setInt(val, &c.Audio.Channels)
	case "audio.format":
		return setString(val, &c.Audio.Format)
	case "segment.frame_ms":
		return setInt(val, &c.Segment.FrameMs)
	case "segment.vad":
		return setBool(val, &c.Segment.VAD)
	case "segment.vad_rms_threshold":
		return setFloat(val, &c.Segment.VADRMS)
	case "segment.hop_ms":
		return setInt(val, &c.Segment.HopMs)
	case "segment.min_speech_ms":
		return setInt(val, &c.Segment.MinSpeechMs)
	case "segment.min_segment_ms":
		return setInt(val, &c.Segment.MinSegmentMs)
	case "segment.max_stretch_ms":
		return setInt(val, &c.Segment.MaxStretchMs)
	case "adapter.cmd":
		return setString(val, &c.Adapter.Cmd)
	case "adapter.args":
		return setStringArray(val, &c.Adapter.Args)
	case "runner.max_restarts":
		return setInt(val, &c.Runner.MaxRestarts)
	case "runner.restart_window_s":
		return setInt(val, &c.Runner.RestartWindowS)
	case "output.partials":
		return setBool(val, &c.Output.Partials)
	default:
		return fmt.Errorf("unknown key %q in section %q", key, section)
	}
}

func unquote(v string) (string, error) {
	if len(v) < 2 || v[0] != '"' || v[len(v)-1] != '"' {
		return "", fmt.Errorf("expected quoted string, got %q", v)
	}
	return v[1 : len(v)-1], nil
}

func setString(v string, dst *string) error {
	s, err := unquote(v)
	if err != nil {
		return err
	}
	*dst = s
	return nil
}

func setInt(v string, dst *int) error {
	n, err := strconv.Atoi(v)
	if err != nil {
		return fmt.Errorf("expected integer, got %q", v)
	}
	*dst = n
	return nil
}

func setFloat(v string, dst *float64) error {
	f, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return fmt.Errorf("expected number, got %q", v)
	}
	*dst = f
	return nil
}

func setBool(v string, dst *bool) error {
	switch v {
	case "true":
		*dst = true
	case "false":
		*dst = false
	default:
		return fmt.Errorf("expected true|false, got %q", v)
	}
	return nil
}

func setStringArray(v string, dst *[]string) error {
	v = strings.TrimSpace(v)
	if len(v) < 2 || v[0] != '[' || v[len(v)-1] != ']' {
		return fmt.Errorf("expected [\"a\", ...], got %q", v)
	}
	out := []string{}
	for _, part := range strings.Split(v[1:len(v)-1], ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		s, err := unquote(part)
		if err != nil {
			return err
		}
		out = append(out, s)
	}
	*dst = out
	return nil
}
