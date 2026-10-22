package segment

import (
	"context"
	"math"
	"strings"
	"testing"
)

const rate = 16000

// pcm helpers ---------------------------------------------------------------

func silence(ms int) []byte { return make([]byte, rate*2*ms/1000) }

// speech returns a 440 Hz sine at the given amplitude (RMS = amp/√2 ≈ 0.14
// for amp 0.2, well above the default threshold).
func speech(ms int, amp float64) []byte {
	n := rate * ms / 1000
	b := make([]byte, 2*n)
	for i := range b {
		b[i] = 0
	}
	for i := 0; i < n; i++ {
		v := int16(amp * 32767 * math.Sin(2*math.Pi*440*float64(i)/rate))
		b[2*i] = byte(uint16(v) & 0xff)
		b[2*i+1] = byte(uint16(v) >> 8)
	}
	return b
}

func opts(vad bool) Options {
	return Options{
		Rate: rate, Channels: 1, FrameMs: 2000, HopMs: 30,
		Threshold: 0.01, MinSpeechMs: 0,
		MaxStretchMs: 300, VAD: vad,
	}
}

func collect(t *testing.T, pcm []byte, o Options) []Segment {
	t.Helper()
	segs, err := drain(pcm, o)
	if err != nil {
		t.Fatal(err)
	}
	return segs
}

func drain(pcm []byte, o Options) ([]Segment, error) {
	ctx := context.Background()
	var out []Segment
	for s := range Segments(ctx, strings.NewReader(string(pcm)), o) {
		out = append(out, s)
	}
	return out, nil
}

// tests ---------------------------------------------------------------------

// S3.1 invariant: segments tile the input with no gaps and no overlap.
func TestSegmentsTileTheStream(t *testing.T) {
	pcm := concat(silence(2000), speech(1500, 0.2), silence(2500), speech(900, 0.2), silence(1100))
	for _, vad := range []bool{true, false} {
		segs := collect(t, pcm, opts(vad))
		var total int
		for i, s := range segs {
			total += len(s.Data)
			if i > 0 && math.Abs(s.T0-segs[i-1].T1) > 1e-9 {
				t.Fatalf("vad=%v: gap/overlap between segment %d and %d: %v != %v", vad, i-1, i, segs[i-1].T1, s.T0)
			}
		}
		if total != len(pcm) {
			t.Fatalf("vad=%v: segments carry %d bytes, input has %d", vad, total, len(pcm))
		}
	}
}

// S3.3: silence-only segments are marked non-speech (the caller drops them,
// so sustained silence emits no events). Speech segments are marked speech.
func TestVADSilenceSkip(t *testing.T) {
	pcm := concat(silence(2000), speech(1500, 0.2), silence(2500), speech(900, 0.2))
	segs := collect(t, pcm, opts(true))
	if len(segs) == 0 {
		t.Fatal("no segments")
	}
	for _, s := range segs {
		speechMS := overlapSpeechMS(s)
		if s.Speech != (speechMS > 0) {
			t.Fatalf("segment [%v,%v]: Speech=%v but speech duration is %d ms", s.T0, s.T1, s.Speech, speechMS)
		}
	}
	// Each speech island must be covered by sent segments (allowing a force
	// cut to split an island across two consecutive sent segments).
	islands := [][2]float64{{2.0, 3.5}, {6.0, 6.9}}
	var sent [][2]float64
	for _, s := range segs {
		if s.Speech {
			sent = append(sent, [2]float64{s.T0, s.T1})
		}
	}
	cover := func(lo, hi float64) bool {
		for _, iv := range sent {
			if iv[0] <= lo+0.15 && iv[1] >= hi-0.15 {
				return true
			}
		}
		// split across consecutive sent segments?
		for a := 0; a < len(sent); a++ {
			for b := a; b < len(sent); b++ {
				if sent[a][0] <= lo+0.15 && sent[b][1] >= hi-0.15 {
					contiguous := true
					for k := a; k < b; k++ {
						if sent[k][1] != sent[k+1][0] {
							contiguous = false
						}
					}
					if contiguous {
						return true
					}
				}
			}
		}
		return false
	}
	for _, is := range islands {
		if !cover(is[0], is[1]) {
			t.Fatalf("speech island %v not covered by sent segments %v", is, sent)
		}
	}
}

// The look-back window places cuts at energy minima: a pause before the
// boundary wins over the fixed 2 s position.
func TestVADCutAtEnergyDip(t *testing.T) {
	// speech 0-1.8, pause 1.8-1.95, speech 1.95-4.0: boundary 2.0 must cut
	// inside the pause, not at 2.0 (mid-speech).
	pcm := concat(speech(1800, 0.2), silence(150), speech(2050, 0.2))
	segs := collect(t, pcm, opts(true))
	if len(segs) < 2 {
		t.Fatalf("expected >= 2 segments, got %d", len(segs))
	}
	if segs[0].T1 < 1.795 || segs[0].T1 > 1.95 {
		t.Fatalf("cut at %v, want inside pause [1.8, 1.95]", segs[0].T1)
	}
}

// Continuous speech past the boundary stretches the segment up to
// MaxStretchMs to reach a dip (bounded latency, no mid-word cut if avoidable).
func TestVADStretch(t *testing.T) {
	// No dip anywhere: cap stretch at 300 ms -> first cut in (2.0, 2.3].
	pcm := concat(speech(5000, 0.2))
	segs := collect(t, pcm, opts(true))
	if segs[0].T1 <= 2.0 || segs[0].T1 > 2.3+0.03 {
		t.Fatalf("no-dip cut at %v, want in (2.0, 2.33]", segs[0].T1)
	}

	// Short dip just past the boundary: cut there.
	pcm2 := concat(speech(2150, 0.2), silence(60), speech(2790, 0.2))
	segs2 := collect(t, pcm2, opts(true))
	if segs2[0].T1 < 2.15 || segs2[0].T1 > 2.21 {
		t.Fatalf("dip cut at %v, want in [2.15, 2.21]", segs2[0].T1)
	}
}

// VAD off keeps the Stage 1 fixed framing (baseline / regression path).
func TestNoVADFixedFrames(t *testing.T) {
	pcm := concat(speech(4500, 0.2), silence(500))
	segs := collect(t, pcm, opts(false))
	want := (len(pcm) + rate*2*2 - 1) / (rate * 2 * 2) // 2 s frames: 2 full + 1 short
	if len(segs) != want {
		t.Fatalf("got %d segments, want %d", len(segs), want)
	}
	for i, s := range segs[:len(segs)-1] {
		if len(s.Data) != rate*2*2 {
			t.Fatalf("segment %d: %d bytes, want full frame", i, len(s.Data))
		}
		if !s.Speech {
			t.Fatalf("segment %d: Speech=false with VAD off", i)
		}
	}
}

// A short word onset just before a boundary dip must survive: either its
// segment is sent (trailing protection) or the cut lands before the onset so
// the word is complete in the next segment. Dropping the word is the failure
// (regression: repeated clips lost "Ever" at every boundary).
func TestVADTrailingOnsetProtection(t *testing.T) {
	// long silence + "Ever" 0.2s + dip 0.06s + continuing speech; with a
	// min_speech_ms gate of 300 the onset segment (0.2 s of speech) would be
	// dropped — the trailing window must protect it.
	o := opts(true)
	o.MinSpeechMs = 300
	pcm := concat(silence(1700), speech(200, 0.2), silence(60), speech(2000, 0.2))
	segs := collect(t, pcm, o)
	if len(segs) < 2 {
		t.Fatalf("expected >= 2 segments, got %d", len(segs))
	}
	for _, s := range segs {
		if s.Speech && s.T0 <= 1.72 && s.T1 >= 1.88 {
			return // onset word [1.7,1.9] contained in a sent segment
		}
	}
	t.Fatalf("onset word [1.7,1.9] not contained in any sent segment: %+v", segs)
}

// helpers -------------------------------------------------------------------

func concat(parts ...[]byte) []byte {
	var out []byte
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

// overlapSpeechMS is the test-model counterpart of the segmenter's speech
// accounting: milliseconds of above-threshold audio in the segment data.
func overlapSpeechMS(s Segment) int {
	samples := len(s.Data) / 2
	hop := rate * 30 / 1000
	speechSamples := 0
	for off := 0; off+hop <= samples; off += hop {
		if rms(s.Data[2*off:2*(off+hop)]) >= 0.01 {
			speechSamples += hop
		}
	}
	return speechSamples * 1000 / rate
}
