// Package segment turns a raw PCM stream into segments for the model adapter.
//
// Stage 3 (docs/ARQUITECTURA.md §4, decision D9): with VAD enabled the stream
// is cut at natural pauses using a classic endpointer. A silence run of >= 3
// analysis hops (>= 90 ms — shorter dips are intra-word closures) ends the
// current segment at the last loud hop, and the pause itself is emitted as a
// non-speech segment: the caller drops those, so silence produces no adapter
// calls and no events. The next segment starts at the following onset minus a
// 200 ms preroll, so soft consonant onsets survive and no sent segment leads
// with silence (leading silence makes moonshine return empty text). Fluent
// speech with no pause is force-cut at the deepest dip between FrameMs and
// FrameMs+MaxStretchMs, bounding segment length and latency.
//
// With VAD disabled the stream is split into fixed FrameMs frames (v1
// behavior, Stage 1). Consecutive segments always tile the stream: each one
// starts where the previous ended (no gaps, no overlap), whether speech or
// skipped silence.
package segment

import (
	"context"
	"io"
	"math"

	"stt/internal/protocol"
)

// prerollMs is the quiet audio included before each detected onset so soft
// consonants at utterance starts are not clipped.
const prerollMs = 200

// minPauseHops is the silence run (in hops) that counts as a pause: 3 hops
// = 90 ms with the default hop. Shorter dips are intra-word closures.
const minPauseHops = 3

// minSegmentS is the minimum audio a segment carries before a pause may cut
// it (1 s): shorter segments fragment phrases and degrade the model.
const minSegmentS = 1

// Options tunes segmentation (mirrors config/stt.toml [segment]).
type Options struct {
	Rate         int
	Channels     int
	FrameMs      int     // target segment duration (force-cut cap)
	HopMs        int     // VAD analysis hop
	Threshold    float64 // speech threshold: RMS of samples normalized to [-1,1]
	MinSpeechMs  int     // minimum speech for a segment to be marked Speech
	MaxStretchMs int     // force-cut: how far past FrameMs fluent speech may run
	VAD          bool
}

// Segment is one variable-length piece of the stream. Speech reports whether
// the segment carries above-threshold audio; the caller drops non-speech
// segments (pause regions between utterances).
type Segment struct {
	protocol.Frame
	Speech bool
}

// Segments reads raw PCM s16le from r and emits segments. The channel closes
// at end of input (any trailing partial region is flushed). Upstream read
// errors end the stream silently, as in Stage 1.
func Segments(ctx context.Context, r io.Reader, o Options) <-chan Segment {
	out := make(chan Segment, 8)
	go func() {
		defer close(out)
		bytesPerSample := 2 * o.Channels
		secPerByte := 1.0 / float64(o.Rate*bytesPerSample)
		bytesPerSecond := o.Rate * bytesPerSample
		hopBytes := bytesPerSecond * o.HopMs / 1000
		frameBytes := bytesPerSecond * o.FrameMs / 1000
		stretchBytes := bytesPerSecond * o.MaxStretchMs / 1000
		minSegBytes := bytesPerSecond * minSegmentS
		prerollBytes := bytesPerSecond * prerollMs / 1000
		minSpeechBytes := bytesPerSecond * o.MinSpeechMs / 1000

		var pending []byte   // audio not emitted yet
		var hopRMS []float64 // RMS per analysis hop inside pending
		var hopEnd []int     // end byte offset (within pending) of each hop

		// State (all offsets relative to pending, reset by rolls):
		//   inPause: the region [0, len) after the last emit is a pause; the
		//            next loud hop is an onset (start of a new utterance).
		//   runStart/runLen: current quiet run inside a speech segment.
		inPause := true // the stream starts quiet: the first onset opens a segment
		runStart, runLen := 0, 0
		tAbs := 0 // bytes already emitted
		idx := 0

		hop := make([]byte, hopBytes)

		// loudNow reports whether the newest hop is above the threshold.
		// Empty until the first hop arrives (e.g. EOF with no audio).
		loudNow := func() bool {
			return len(hopRMS) > 0 && hopRMS[len(hopRMS)-1] > o.Threshold
		}

		// quietest returns the index of the min-RMS hop ending in (lo, hi].
		quietest := func(lo, hi int) int {
			best := -1
			for i := range hopEnd {
				if e := hopEnd[i]; e > lo && e <= hi {
					if best < 0 || hopRMS[i] < hopRMS[best] {
						best = i
					}
				}
			}
			return best
		}

		// emit sends pending[:cut] and rolls the buffers. speech marks the
		// region as a candidate utterance (subject to the MinSpeechMs gate);
		// skip regions (pauses) are always marked non-speech.
		emit := func(cut int, speech bool) bool {
			if cut <= 0 {
				return true
			}
			var speechBytes int
			if speech {
				prev := 0
				trailing := o.Rate * bytesPerSample * 100 / 1000 // onset protection window
				trailingSpeech := false
				for i := range hopEnd {
					if hopEnd[i] > cut {
						break
					}
					if hopRMS[i] >= o.Threshold {
						speechBytes += hopEnd[i] - prev
						if hopEnd[i] > cut-trailing {
							trailingSpeech = true
						}
					}
					prev = hopEnd[i]
				}
				if o.VAD {
					// Send when the segment carries enough speech (MinSpeechMs
					// gate); a segment still containing speech in its trailing
					// ~100 ms is always sent — its end sits on an onset-adjacent
					// pause and dropping it would lose the next utterance's
					// first word. Fixed framing (VAD off) never gates.
					speech = speechBytes > 0 &&
						(speechBytes >= minSpeechBytes || trailingSpeech)
				}
			}
			seg := Segment{
				Frame: protocol.Frame{
					Index: idx,
					Data:  append([]byte(nil), pending[:cut]...),
					T0:    float64(tAbs) * secPerByte,
					T1:    float64(tAbs+cut) * secPerByte,
				},
				Speech: speech,
			}
			select {
			case out <- seg:
			case <-ctx.Done():
				return false
			}
			rest := copy(pending, pending[cut:])
			pending = pending[:rest]
			tAbs += cut
			newRMS := hopRMS[:0]
			newEnd := hopEnd[:0]
			for i := range hopEnd {
				if hopEnd[i] > cut {
					newRMS = append(newRMS, hopRMS[i])
					newEnd = append(newEnd, hopEnd[i]-cut)
				}
			}
			hopRMS, hopEnd = newRMS, newEnd
			runStart, runLen = 0, 0
			idx++
			return true
		}

		for {
			n, err := io.ReadFull(r, hop)
			if n > 0 {
				pending = append(pending, hop[:n]...)
				hopRMS = append(hopRMS, rms(hop[:n]))
				hopEnd = append(hopEnd, len(pending))
			}
			if err != nil && err != io.EOF && err != io.ErrUnexpectedEOF {
				return // upstream error: end the stream
			}

			if !o.VAD {
				if len(pending) >= frameBytes {
					if !emit(frameBytes, true) {
						return
					}
				}
			} else {
				switch {
				case inPause:
					if loudNow() {
						// Onset: emit the pause (minus preroll) as a skip
						// region; the preroll leads the new speech segment.
						onset := hopEnd[len(hopEnd)-1] - hopBytes
						if onset < 0 {
							onset = 0
						}
						cut := onset - prerollBytes
						if cut < 0 {
							cut = 0
						}
						if !emit(cut, false) {
							return
						}
						inPause = false
					} else if len(pending) >= frameBytes {
						// Long pause: drain it in frame-sized skip chunks.
						if !emit(frameBytes, false) {
							return
						}
					}
				default: // building a speech segment since pending start
					if loudNow() {
						runStart, runLen = 0, 0
					} else {
						if runLen == 0 {
							runStart = hopEnd[len(hopEnd)-1] - hopBytes
							if runStart < 0 {
								runStart = 0
							}
						}
						runLen++
						if runLen >= minPauseHops && runStart >= minSegBytes {
							// Real pause after a full segment: end it at the
							// last loud hop; the pause becomes a skip region.
							// Pauses that begin before the minimum never cut
							// here (they would land mid-phrase in alternating
							// short phrases); the force cap bounds those.
							if !emit(runStart, true) {
								return
							}
							inPause = true
						}
					}
					if !inPause && len(pending) >= frameBytes+stretchBytes {
						// Fluent speech: force-cut at the deepest dip near
						// the cap.
						cut := 0
						if b := quietest(frameBytes, frameBytes+stretchBytes); b >= 0 {
							cut = hopEnd[b]
						} else {
							cut = frameBytes
						}
						if !emit(cut, true) {
							return
						}
					}
				}
			}

			if err != nil { // EOF: flush the trailing partial region
				if len(pending) > 0 && !emit(len(pending), !inPause) {
					return
				}
				return
			}
		}
	}()
	return out
}

// rms is the root mean square of little-endian s16 samples, normalized to [-1,1].
func rms(b []byte) float64 {
	n := len(b) / 2
	if n == 0 {
		return 0
	}
	var sum float64
	for i := 0; i+1 < len(b); i += 2 {
		v := float64(int16(uint16(b[i])|uint16(b[i+1])<<8)) / 32768
		sum += v * v
	}
	return math.Sqrt(sum / float64(n))
}
