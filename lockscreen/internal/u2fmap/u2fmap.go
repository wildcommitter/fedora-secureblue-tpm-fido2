// Package u2fmap reads and updates pam_u2f's central mapping file, one line
// per user: "user:cred[:cred...]". /etc/pam.d/hardened-unlock and swaylock
// both point pam_u2f at it with the origin below.
package u2fmap

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const (
	// File is the authfile= of the PAM stacks.
	File = "/etc/u2f_mappings"
	// Origin is their origin= and appid=.
	Origin = "pam://workstation"
	// MaxDevices is their max_devices=: pam_u2f ignores credentials past it.
	MaxDevices = 4
)

// Count returns how many credentials name has in data.
func Count(data []byte, name string) int {
	for _, line := range strings.Split(string(data), "\n") {
		if rest, ok := strings.CutPrefix(line, name+":"); ok && rest != "" {
			return strings.Count(rest, ":") + 1
		}
	}
	return 0
}

// Registered reports whether name has at least one key in the mapping file.
// A missing file means no key.
func Registered(path, name string) (bool, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return Count(data, name) > 0, nil
}

// Add appends cred (pamu2fcfg -n output, ":keyHandle,publicKey,type,options")
// to name's line in data, or adds the line, and returns the new file.
func Add(data []byte, name, cred string) ([]byte, error) {
	cred = strings.TrimSpace(cred)
	if !strings.HasPrefix(cred, ":") || strings.Count(cred, ":") != 1 || strings.ContainsAny(cred, "\n\r") {
		return nil, fmt.Errorf("unexpected pamu2fcfg output %q", cred)
	}
	if n := Count(data, name); n >= MaxDevices {
		return nil, fmt.Errorf("%s already has %d keys (max_devices=%d)", name, n, MaxDevices)
	}
	var out []string
	found := false
	for _, line := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, name+":") {
			line = strings.TrimSuffix(line, ":") + cred
			found = true
		}
		out = append(out, line)
	}
	if !found {
		out = append(out, name+cred)
	}
	return []byte(strings.Join(out, "\n") + "\n"), nil
}

// Write replaces path atomically, root-owned and world-readable (the locker
// reads it as the user). root's umask on secureblue is 027, so the mode is set
// explicitly.
func Write(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".u2f_mappings-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o644); err != nil {
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		return err
	}
	if err := tmp.Sync(); err != nil {
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
