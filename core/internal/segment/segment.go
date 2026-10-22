// Package segment turns a raw PCM stream into fixed-duration frames.
package segment

import (
	"context"
	"io"

	"stt/internal/protocol"
)

// Frames reads raw PCM s16le from r and emits frames of frameMs milliseconds.
// The last frame may be shorter. The channel is closed at end of input.
func Frames(ctx context.Context, r io.Reader, rate, channels, frameMs int) <-chan protocol.Frame {
	out := make(chan protocol.Frame, 8)
	bytesPerSample := 2 * channels
	frameBytes := rate * bytesPerSample / 1000 * frameMs
	secPerByte := 1.0 / float64(rate*bytesPerSample)

	go func() {
		defer close(out)
		buf := make([]byte, frameBytes)
		idx := 0
		offset := 0
		for {
			n, err := io.ReadFull(r, buf)
			if n > 0 {
				fr := protocol.Frame{
					Index: idx,
					Data:  append([]byte(nil), buf[:n]...),
					T0:    float64(offset) * secPerByte,
					T1:    float64(offset+n) * secPerByte,
				}
				select {
				case out <- fr:
				case <-ctx.Done():
					return
				}
				idx++
				offset += n
			}
			if err == io.EOF || err == io.ErrUnexpectedEOF {
				return
			}
			if err != nil {
				return // upstream error: end the stream
			}
		}
	}()
	return out
}
