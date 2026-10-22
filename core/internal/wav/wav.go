// Package wav reads PCM s16le mono 16 kHz WAV files (v1 input convenience).
// Other formats must be converted upstream (e.g. with sox), see docs/CONTRATOS.md §4.
package wav

import (
	"encoding/binary"
	"fmt"
	"io"
	"os"
)

// Open validates the WAV header and returns a reader over the PCM data.
func Open(path string) (io.Reader, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	var riff [12]byte
	if _, err := io.ReadFull(f, riff[:]); err != nil {
		f.Close()
		return nil, fmt.Errorf("wav: %s: not a RIFF file", path)
	}
	if string(riff[0:4]) != "RIFF" || string(riff[8:12]) != "WAVE" {
		f.Close()
		return nil, fmt.Errorf("wav: %s: not a WAVE file", path)
	}

	var (
		format      uint16
		channels    uint16
		rate        uint32
		bits        uint16
		dataOffset  int64 = -1
		dataLen     uint32
		sawFmt      bool
		offset      int64 = 12
	)
	var ch [8]byte
	for {
		if _, err := io.ReadFull(f, ch[:]); err != nil {
			break // EOF: stop scanning
		}
		size := binary.LittleEndian.Uint32(ch[4:8])
		id := string(ch[0:4])
		chunkStart := offset + 8 // payload start
		switch id {
		case "fmt ":
			var fmtBuf [16]byte
			if _, err := io.ReadFull(f, fmtBuf[:]); err != nil {
				f.Close()
				return nil, fmt.Errorf("wav: %s: truncated fmt chunk", path)
			}
			format = binary.LittleEndian.Uint16(fmtBuf[0:2])
			channels = binary.LittleEndian.Uint16(fmtBuf[2:4])
			rate = binary.LittleEndian.Uint32(fmtBuf[4:8])
			bits = binary.LittleEndian.Uint16(fmtBuf[14:16])
			sawFmt = true
		case "data":
			dataOffset = chunkStart
			dataLen = size
		}
		// advance to next chunk header: payload + pad byte on odd sizes
		adv := int64(size)
		if adv%2 == 1 {
			adv++
		}
		if _, err := f.Seek(chunkStart+adv, io.SeekStart); err != nil {
			break
		}
		offset = chunkStart + adv
	}

	if !sawFmt || dataOffset < 0 {
		f.Close()
		return nil, fmt.Errorf("wav: %s: missing fmt/data chunk", path)
	}
	if format != 1 || bits != 16 || channels != 1 || rate != 16000 {
		f.Close()
		return nil, fmt.Errorf(
			"wav: %s: unsupported format (got format=%d bits=%d channels=%d rate=%d); "+
				"v1 requires PCM s16le 16 kHz mono — convert with: sox in.wav -r 16000 -c 1 -b 16 out.wav",
			path, format, bits, channels, rate)
	}

	if _, err := f.Seek(dataOffset, io.SeekStart); err != nil {
		f.Close()
		return nil, err
	}
	return io.LimitReader(newReadCloser(f), int64(dataLen)), nil
}

type readCloser struct {
	f *os.File
}

func newReadCloser(f *os.File) *readCloser { return &readCloser{f: f} }

func (r *readCloser) Read(p []byte) (int, error) { return r.f.Read(p) }

func (r *readCloser) Close() error { return r.f.Close() }
