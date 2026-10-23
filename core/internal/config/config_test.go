package config

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestDefaults(t *testing.T) {
	c := Default()
	if c.Audio.Rate != 16000 || c.Audio.Channels != 1 || c.Audio.Format != "s16le" {
		t.Fatalf("audio defaults: %+v", c.Audio)
	}
	if !c.Segment.VAD || c.Segment.FrameMs != 5000 || c.Segment.VADRMS != 0.01 ||
		c.Segment.HopMs != 30 || c.Segment.MinSpeechMs != 0 ||
		c.Segment.MinSegmentMs != 3000 || c.Segment.MaxStretchMs != 300 {
		t.Fatalf("segment defaults: %+v", c.Segment)
	}
	if c.Output.Partials {
		t.Fatal("partials must default to false")
	}
	if c.Output.Listen != "" {
		t.Fatalf("fan-out listener must default to empty, got %q", c.Output.Listen)
	}
}

func TestLoadMissingFile(t *testing.T) {
	// Optional path: defaults silently. Explicit path: error.
	c, err := Load(filepath.Join(t.TempDir(), "nope.toml"), false)
	if err != nil {
		t.Fatalf("optional load: %v", err)
	}
	if !reflect.DeepEqual(c, Default()) {
		t.Fatal("missing file must yield defaults")
	}
	if _, err := Load(filepath.Join(t.TempDir(), "nope.toml"), true); err == nil {
		t.Fatal("explicit missing file must error")
	}
}

func TestParse(t *testing.T) {
	src := `
# full-line comment
[audio]
rate = 16000        # trailing comment
channels = 1
format = "s16le"

[segment]
frame_ms = 2000
vad = true
vad_rms_threshold = 0.015
hop_ms = 30
min_speech_ms = 250
min_segment_ms = 2500
max_stretch_ms = 250

[adapter]
cmd = "adapters/moonshine/stt-adapter-moonshine"
args = ["--model", "var/models/moonshine-tiny", "--threads", "4"]

[runner]
max_restarts = 5
restart_window_s = 30

[output]
partials = true
listen = "tcp://127.0.0.1:4714"
`
	path := filepath.Join(t.TempDir(), "stt.toml")
	if err := os.WriteFile(path, []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	c, err := Load(path, true)
	if err != nil {
		t.Fatal(err)
	}
	if c.Segment.VADRMS != 0.015 || c.Segment.MinSpeechMs != 250 ||
		c.Segment.MinSegmentMs != 2500 || c.Segment.MaxStretchMs != 250 || !c.Segment.VAD {
		t.Fatalf("segment: %+v", c.Segment)
	}
	if c.Adapter.Cmd != "adapters/moonshine/stt-adapter-moonshine" {
		t.Fatalf("adapter cmd: %q", c.Adapter.Cmd)
	}
	want := []string{"--model", "var/models/moonshine-tiny", "--threads", "4"}
	if len(c.Adapter.Args) != len(want) {
		t.Fatalf("args: %v", c.Adapter.Args)
	}
	for i := range want {
		if c.Adapter.Args[i] != want[i] {
			t.Fatalf("args[%d] = %q, want %q", i, c.Adapter.Args[i], want[i])
		}
	}
	if c.Runner.MaxRestarts != 5 || c.Runner.RestartWindowS != 30 {
		t.Fatalf("runner: %+v", c.Runner)
	}
	if !c.Output.Partials {
		t.Fatal("partials: want true")
	}
	if c.Output.Listen != "tcp://127.0.0.1:4714" {
		t.Fatalf("listen = %q", c.Output.Listen)
	}
}

func TestParseUnknownKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bad.toml")
	if err := os.WriteFile(path, []byte("[segment]\nframee_ms = 5\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path, true); err == nil {
		t.Fatal("unknown key must error")
	}
}
