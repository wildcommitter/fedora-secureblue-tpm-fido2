// Package duress implements the lock screen's canary password. The canary is
// stored as a yescrypt hash (libxcrypt) in File. Every answer typed at the
// lock screen is checked against it before it reaches PAM or the key. On a
// match the locker asks the root helper (cmd/duress-reset) to hard-reset the
// machine, so the disk is back behind tokenvault.
package duress

/*
#cgo LDFLAGS: -lcrypt
#include <crypt.h>
#include <stdlib.h>
#include <string.h>

// hu_crypt hashes key with setting into out (CRYPT_OUTPUT_SIZE bytes).
// The crypt_data scratch area, which holds key-derived state, is wiped
// before it's freed. Returns 0 on success.
static int hu_crypt(const char *key, const char *setting, char *out) {
	struct crypt_data *cd = calloc(1, sizeof(*cd));
	if (!cd) {
		return -1;
	}
	char *r = crypt_r(key, setting, cd);
	int rc = -1;
	if (r && r[0] != '*') {
		strncpy(out, r, CRYPT_OUTPUT_SIZE - 1);
		out[CRYPT_OUTPUT_SIZE - 1] = 0;
		rc = 0;
	}
	explicit_bzero(cd, sizeof(*cd));
	free(cd);
	return rc;
}

// hu_gensalt writes a fresh yescrypt setting (default cost) into out.
static int hu_gensalt(char *out) {
	return crypt_gensalt_rn("$y$", 0, NULL, 0, out, CRYPT_GENSALT_OUTPUT_SIZE) ? 0 : -1;
}

static void hu_wipe(void *p, size_t n) {
	explicit_bzero(p, n);
}
*/
import "C"

import (
	"bytes"
	"crypto/subtle"
	"errors"
	"fmt"
	"os"
	"strings"
	"unsafe"
)

const (
	// File holds the canary hash: root:hardened-duress 0640, so the locker
	// (its user is in the group) can read it and other users can't.
	File = "/etc/hardened-unlock/duress"
	// Group may read File and connect to the reset helper's socket.
	Group = "hardened-duress"
	// Socket is where cmd/duress-reset listens (hardened-unlock-duress.socket).
	Socket = "/run/hardened-unlock/duress.sock"
	// Request is the one byte the helper accepts.
	Request = 'R'
)

// Canary is a loaded canary hash.
type Canary struct {
	hash string
}

// Load reads the canary hash from path. It returns (nil, nil) when the file
// doesn't exist: no canary set. Errors never include the hash.
func Load(path string) (*Canary, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("duress: read %s: %w", path, err)
	}
	return Parse(data)
}

// Parse validates a canary file's contents: one yescrypt hash line.
func Parse(data []byte) (*Canary, error) {
	h := strings.TrimSpace(string(data))
	if strings.ContainsAny(h, "\n\r \t") || !strings.HasPrefix(h, "$y$") ||
		len(h) < 20 || len(h) >= C.CRYPT_OUTPUT_SIZE {
		return nil, errors.New("duress: malformed canary file (want one yescrypt hash)")
	}
	// A hash that libxcrypt can't evaluate would never match: reject it now
	// so status and the locker report it.
	if _, err := cryptHash([]byte("probe"), h); err != nil {
		return nil, errors.New("duress: malformed canary file (libxcrypt rejects the hash)")
	}
	return &Canary{hash: h}, nil
}

// Match reports whether secret is the canary. An empty secret never matches.
func (c *Canary) Match(secret []byte) bool {
	if c == nil || len(secret) == 0 {
		return false
	}
	got, err := cryptHash(secret, c.hash)
	if err != nil {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(c.hash)) == 1
}

// Hash returns a new yescrypt hash of secret, for `hardened-unlock duress set`.
func Hash(secret []byte) (string, error) {
	if len(secret) == 0 {
		return "", errors.New("duress: empty canary")
	}
	var setting [C.CRYPT_GENSALT_OUTPUT_SIZE]C.char
	if C.hu_gensalt(&setting[0]) != 0 {
		return "", errors.New("duress: crypt_gensalt failed")
	}
	return cryptHash(secret, C.GoString(&setting[0]))
}

// Verify checks secret against any crypt(3) hash, e.g. a shadow entry.
func Verify(secret []byte, hash string) bool {
	if len(secret) == 0 || hash == "" {
		return false
	}
	got, err := cryptHash(secret, hash)
	return err == nil && subtle.ConstantTimeCompare([]byte(got), []byte(hash)) == 1
}

// cryptHash runs crypt_r on a C copy of secret that's wiped afterwards.
func cryptHash(secret []byte, setting string) (string, error) {
	if bytes.IndexByte(secret, 0) >= 0 {
		return "", errors.New("duress: NUL in secret")
	}
	buf := make([]byte, len(secret)+1)
	copy(buf, secret)
	key := C.CBytes(buf)
	clear(buf)
	defer func() {
		C.hu_wipe(key, C.size_t(len(secret)+1))
		C.free(key)
	}()
	cs := C.CString(setting)
	defer C.free(unsafe.Pointer(cs))
	var out [C.CRYPT_OUTPUT_SIZE]C.char
	if C.hu_crypt((*C.char)(key), cs, &out[0]) != 0 {
		return "", errors.New("duress: crypt failed")
	}
	return C.GoString(&out[0]), nil
}
