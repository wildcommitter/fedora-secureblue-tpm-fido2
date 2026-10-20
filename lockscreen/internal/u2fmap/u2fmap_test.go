package u2fmap

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const credA = ":hA,pkA,es256,+presence+pin"
const credB = ":hB,pkB,es256,+presence+pin"

func TestAddNewAndAppend(t *testing.T) {
	data, err := Add(nil, "alice", credA)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "alice"+credA+"\n" {
		t.Fatalf("new line: %q", data)
	}
	data, err = Add(append(data, []byte("bob"+credA+"\n")...), "alice", credB)
	if err != nil {
		t.Fatal(err)
	}
	want := "alice" + credA + credB + "\nbob" + credA + "\n"
	if string(data) != want {
		t.Fatalf("append: %q, want %q", data, want)
	}
	if Count(data, "alice") != 2 || Count(data, "bob") != 1 || Count(data, "al") != 0 {
		t.Fatalf("counts: alice=%d bob=%d al=%d", Count(data, "alice"), Count(data, "bob"), Count(data, "al"))
	}
}

func TestAddRefuses(t *testing.T) {
	full := []byte("alice" + strings.Repeat(credA, MaxDevices) + "\n")
	if _, err := Add(full, "alice", credB); err == nil {
		t.Fatal("added past max_devices")
	}
	for _, bad := range []string{"", "alice" + credA, credA + credB, credA + "\nmallory" + credB} {
		if _, err := Add(nil, "alice", bad); err == nil {
			t.Fatalf("accepted %q", bad)
		}
	}
}

func TestRegisteredAndWrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "u2f_mappings")
	if ok, err := Registered(path, "alice"); ok || err != nil {
		t.Fatalf("missing file: %v %v", ok, err)
	}
	if err := Write(path, []byte("bob"+credA+"\nalice:\n")); err != nil {
		t.Fatal(err)
	}
	if ok, _ := Registered(path, "alice"); ok {
		t.Fatal("empty line counted as a key")
	}
	if ok, _ := Registered(path, "bob"); !ok {
		t.Fatal("bob not registered")
	}
	if fi, _ := os.Stat(path); fi.Mode().Perm() != 0o644 {
		t.Fatalf("mode %o", fi.Mode().Perm())
	}
}
