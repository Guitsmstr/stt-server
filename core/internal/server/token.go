package server

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// DefaultTokenFile is where sttd stores its generated bearer token
// (docs/CONTRATOS.md §9.2).
const DefaultTokenFile = "var/etc/stt-token"

// TokenConfig resolves the sttd bearer token.
type TokenConfig struct {
	Token     string // inline token (--token / [server] token); wins over the file
	TokenFile string // token file path; DefaultTokenFile when empty
}

// LoadToken resolves the bearer token: inline first, then the token file.
// A missing file is generated once (32 random bytes, hex encoded, mode 0600)
// and read back. The returned source is "inline", "file" or "generated"
// (for the startup log; the token itself is never logged).
func LoadToken(cfg TokenConfig) (string, string, error) {
	if cfg.Token != "" {
		return cfg.Token, "inline", nil
	}
	path := cfg.TokenFile
	if path == "" {
		path = DefaultTokenFile
	}
	tok, err := readTokenFile(path)
	if err == nil {
		return tok, "file", nil
	}
	if !errors.Is(err, fs.ErrNotExist) {
		return "", "", err
	}
	if err := generateTokenFile(path); err != nil {
		return "", "", err
	}
	// Read back what we wrote: fail loudly instead of serving a token we
	// never verified.
	tok, err = readTokenFile(path)
	if err != nil {
		return "", "", err
	}
	return tok, "generated", nil
}

// readTokenFile reads and validates an existing token file. A single
// trailing newline is tolerated (echo-friendly). Anything that is not a
// regular file holding 64 hex characters is an error: the token is never
// silently regenerated, so a corrupt file cannot quietly rotate credentials.
func readTokenFile(path string) (string, error) {
	fi, err := os.Stat(path)
	if err != nil {
		return "", err
	}
	if !fi.Mode().IsRegular() {
		return "", fmt.Errorf("token file %s is not a regular file", path)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	tok := strings.TrimSuffix(string(data), "\n")
	tok = strings.TrimSuffix(tok, "\r")
	if !isHex64(tok) {
		return "", fmt.Errorf("token file %s: invalid token (want 64 hex chars); fix or remove the file to regenerate", path)
	}
	return tok, nil
}

// generateTokenFile writes a fresh 64-hex-char token with mode 0600,
// creating parent directories as needed.
func generateTokenFile(path string) error {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return fmt.Errorf("generate token: %w", err)
	}
	tok := hex.EncodeToString(b[:])
	if dir := filepath.Dir(path); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return fmt.Errorf("create token dir: %w", err)
		}
	}
	if err := os.WriteFile(path, []byte(tok+"\n"), 0o600); err != nil {
		return fmt.Errorf("write token file: %w", err)
	}
	return nil
}

// tokenEqual compares two tokens in constant time. SHA-256 digests are
// compared so the duration does not leak the token length (both digests are
// 32 bytes whatever the inputs).
func tokenEqual(a, b string) bool {
	da := sha256.Sum256([]byte(a))
	db := sha256.Sum256([]byte(b))
	return subtle.ConstantTimeCompare(da[:], db[:]) == 1
}

// isHex64 reports whether s is exactly 64 hexadecimal characters.
func isHex64(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, c := range s {
		switch {
		case c >= '0' && c <= '9', c >= 'a' && c <= 'f', c >= 'A' && c <= 'F':
		default:
			return false
		}
	}
	return true
}
