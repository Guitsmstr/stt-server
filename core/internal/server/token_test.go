package server

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadTokenGenerates(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "var", "etc", "stt-token") // parents created

	tok, source, err := LoadToken(TokenConfig{TokenFile: path})
	if err != nil {
		t.Fatalf("LoadToken: %v", err)
	}
	if source != "generated" {
		t.Fatalf("source = %q, want %q", source, "generated")
	}
	if !isHex64(tok) {
		t.Fatalf("generated token is not 64 hex chars: %q", tok)
	}
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !fi.Mode().IsRegular() {
		t.Fatalf("token file is not a regular file: %v", fi.Mode())
	}
	if got := fi.Mode().Perm(); got != 0o600 {
		t.Fatalf("token file mode = %o, want 600", got)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSuffix(string(data), "\n"); got != tok {
		t.Fatalf("file holds %q, want the generated token %q", got, tok)
	}
	if !strings.HasSuffix(string(data), "\n") {
		t.Fatal("token file should end with a newline")
	}
}

func TestLoadTokenReloadStable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stt-token")
	first, _, err := LoadToken(TokenConfig{TokenFile: path})
	if err != nil {
		t.Fatal(err)
	}
	second, source, err := LoadToken(TokenConfig{TokenFile: path})
	if err != nil {
		t.Fatal(err)
	}
	if source != "file" {
		t.Fatalf("source = %q, want %q", source, "file")
	}
	if first != second {
		t.Fatalf("reload regenerated the token: %q vs %q", first, second)
	}
}

func TestLoadTokenInvalidExistingFile(t *testing.T) {
	cases := map[string]string{
		"too short":     "abcdef",
		"bad charset":   strings.Repeat("z", 64),
		"not hex":       strings.Repeat("0", 63) + "g",
		"empty":         "",
		"garbage json":  `{"type":"start"}`,
		"trailing junk": strings.Repeat("a", 64) + "xyz\n",
	}
	for name, content := range cases {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "stt-token")
			if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
				t.Fatal(err)
			}
			before, _ := os.ReadFile(path)
			if _, _, err := LoadToken(TokenConfig{TokenFile: path}); err == nil {
				t.Fatal("invalid token file must error, not regenerate")
			}
			after, _ := os.ReadFile(path)
			if string(before) != string(after) {
				t.Fatal("invalid token file must not be rewritten")
			}
		})
	}
}

func TestLoadTokenTrimsNewline(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stt-token")
	tok := strings.Repeat("0123456789abcdef", 4) // 64 hex
	if err := os.WriteFile(path, []byte(tok+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	got, source, err := LoadToken(TokenConfig{TokenFile: path})
	if err != nil {
		t.Fatal(err)
	}
	if source != "file" || got != tok {
		t.Fatalf("got (%q, %q), want (%q, file)", got, source, tok)
	}
}

func TestLoadTokenNotRegularFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "etc")
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	if _, _, err := LoadToken(TokenConfig{TokenFile: path}); err == nil {
		t.Fatal("non-regular token file must error")
	}
}

func TestLoadTokenInlineWins(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "stt-token") // must NOT be created
	inline := strings.Repeat("ab", 32)
	got, source, err := LoadToken(TokenConfig{Token: inline, TokenFile: path})
	if err != nil {
		t.Fatal(err)
	}
	if source != "inline" || got != inline {
		t.Fatalf("got (%q, %q), want (%q, inline)", got, source, inline)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("inline token must not touch the token file")
	}
}

func TestTokenEqual(t *testing.T) {
	a := strings.Repeat("0123456789abcdef", 4)
	if !tokenEqual(a, a) {
		t.Fatal("equal tokens must compare equal")
	}
	if tokenEqual(a, strings.Repeat("0123456789abcdef", 4)+"0") {
		t.Fatal("different length must compare different")
	}
	if tokenEqual(a, "b"+a[1:]) {
		t.Fatal("different tokens must compare different")
	}
	// Empty vs empty compares equal by construction; the auth path never
	// reaches it (a hub without a token refuses to start, and a missing
	// client token stays "" against a non-empty server token).
	if tokenEqual("", "") != true {
		t.Fatal("empty vs empty must compare equal")
	}
	if tokenEqual("", a) {
		t.Fatal("empty vs non-empty must compare different")
	}
}
