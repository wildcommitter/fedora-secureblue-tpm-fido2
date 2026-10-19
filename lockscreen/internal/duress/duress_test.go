package duress

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHashMatch(t *testing.T) {
	h, err := Hash([]byte("red-umbrella-42"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(h, "$y$") {
		t.Fatalf("not a yescrypt hash: %q", h)
	}
	c, err := Parse([]byte(h + "\n"))
	if err != nil {
		t.Fatal(err)
	}
	if !c.Match([]byte("red-umbrella-42")) {
		t.Fatal("canary does not match itself")
	}
	for _, s := range []string{"", "red-umbrella-4", "red-umbrella-42 ", "RED-UMBRELLA-42"} {
		if c.Match([]byte(s)) {
			t.Fatalf("%q matched the canary", s)
		}
	}
	if !Verify([]byte("red-umbrella-42"), h) || Verify([]byte("x"), h) || Verify(nil, h) {
		t.Fatal("Verify disagrees with Match")
	}
}

func TestHashRejectsEmptyAndNUL(t *testing.T) {
	if _, err := Hash(nil); err == nil {
		t.Fatal("empty canary hashed")
	}
	if _, err := Hash([]byte("a\x00b")); err == nil {
		t.Fatal("canary with NUL hashed")
	}
}

func TestNilCanaryNeverMatches(t *testing.T) {
	var c *Canary
	if c.Match([]byte("anything")) {
		t.Fatal("nil canary matched")
	}
}

func TestLoadMissingFile(t *testing.T) {
	c, err := Load(filepath.Join(t.TempDir(), "duress"))
	if c != nil || err != nil {
		t.Fatalf("missing file: got (%v, %v), want (nil, nil)", c, err)
	}
}

func TestLoadMalformed(t *testing.T) {
	good, err := Hash([]byte("canary"))
	if err != nil {
		t.Fatal(err)
	}
	for name, data := range map[string]string{
		"empty":      "",
		"garbage":    "not a hash",
		"sha512":     "$6$saltsalt$" + strings.Repeat("a", 86),
		"two hashes": good + "\n" + good,
		"bad params": "$y$zzz$abcdefghijklmnop$abcdefghijklmnopqrstuvwxyz012345678",
	} {
		path := filepath.Join(t.TempDir(), "duress")
		if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
			t.Fatal(err)
		}
		c, err := Load(path)
		if c != nil || err == nil {
			t.Fatalf("%s: got (%v, %v), want an error", name, c, err)
		}
		if strings.Contains(err.Error(), "$") || (data != "" && strings.Contains(err.Error(), data)) {
			t.Fatalf("%s: error leaks the hash: %v", name, err)
		}
	}
}

func TestLoadUnreadable(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads any file")
	}
	path := filepath.Join(t.TempDir(), "duress")
	if err := os.WriteFile(path, []byte("x"), 0); err != nil {
		t.Fatal(err)
	}
	if c, err := Load(path); c != nil || err == nil {
		t.Fatalf("unreadable file: got (%v, %v), want an error", c, err)
	}
}
