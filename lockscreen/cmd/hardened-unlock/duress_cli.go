package main

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"golang.org/x/term"

	"hardened-unlock/internal/duress"
)

const tokenvaultConf = "/etc/tokenvault/tokenvault.conf"

const duressUsage = `usage: hardened-unlock duress set|clear|status [--user NAME]   (as root)
  set     ask for a canary twice and store its yescrypt hash; typing it at the
          lock screen hard-resets the machine instead of unlocking
  clear   remove the canary
  status  show whether a canary is set and the reset path works
NAME defaults to the user who ran run0/sudo.
`

// duressCLI implements `hardened-unlock duress ...`.
func duressCLI(args []string) int {
	if len(args) == 0 {
		fmt.Fprint(os.Stderr, duressUsage)
		return 2
	}
	cmd, rest := args[0], args[1:]
	name := os.Getenv("SUDO_USER")
	for i := 0; i < len(rest); i++ {
		if rest[i] == "--user" && i+1 < len(rest) {
			name = rest[i+1]
			i++
			continue
		}
		fmt.Fprint(os.Stderr, duressUsage)
		return 2
	}
	if os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "hardened-unlock duress: run as root (run0 hardened-unlock duress ...)")
		return 1
	}
	var err error
	switch cmd {
	case "set":
		err = duressSet(name)
	case "clear":
		err = duressClear()
	case "status":
		err = duressStatus(name)
	default:
		fmt.Fprint(os.Stderr, duressUsage)
		return 2
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "hardened-unlock duress:", err)
		return 1
	}
	return 0
}

func duressSet(name string) error {
	if name == "" {
		return errors.New("no user: pass --user NAME")
	}
	u, err := user.Lookup(name)
	if err != nil {
		return err
	}
	grp, err := user.LookupGroup(duress.Group)
	if err != nil {
		return fmt.Errorf("group %s missing (systemd-sysusers creates it at boot): %w", duress.Group, err)
	}
	gid, _ := strconv.Atoi(grp.Gid)

	fmt.Fprintln(os.Stderr, "The canary must differ from the key PIN, the TPM2 PIN and the account password.")
	in := bufio.NewReader(os.Stdin)
	first, err := readSecret(in, "Duress canary: ")
	if err != nil {
		return err
	}
	defer zero(first)
	second, err := readSecret(in, "Again: ")
	if err != nil {
		return err
	}
	defer zero(second)
	if len(first) == 0 {
		return errors.New("empty canary refused")
	}
	if !bytes.Equal(first, second) {
		return errors.New("the two entries differ")
	}
	if err := checkNotACredential(name, first); err != nil {
		return err
	}

	hash, err := duress.Hash(first)
	if err != nil {
		return err
	}
	if err := writeCanary(hash, gid); err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "canary set in", duress.File)

	ids, _ := u.GroupIds()
	if !slices.Contains(ids, grp.Gid) {
		if out, err := exec.Command("gpasswd", "-a", name, duress.Group).CombinedOutput(); err != nil {
			return fmt.Errorf("add %s to %s: %v: %s", name, duress.Group, err, out)
		}
		fmt.Fprintf(os.Stderr, "added %s to %s: log out and back in before the lock screen can use it\n",
			name, duress.Group)
	}
	return nil
}

// checkNotACredential refuses a canary that equals the account password or
// one of tokenvault's PINs (the FIDO2 PIN is the key PIN the lock screen
// asks). A canary equal to a real secret would reset on every unlock.
func checkNotACredential(name string, canary []byte) error {
	if hash := shadowHash(name); hash != "" && duress.Verify(canary, hash) {
		return errors.New("the canary is the account password: refused")
	}
	for k, v := range readTokenvaultPINs() {
		if v != "" && v == string(canary) {
			return fmt.Errorf("the canary is tokenvault's %s: refused", k)
		}
	}
	return nil
}

// shadowHash returns name's password hash from /etc/shadow, or "".
func shadowHash(name string) string {
	data, err := os.ReadFile("/etc/shadow")
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Split(line, ":")
		if len(f) > 1 && f[0] == name && strings.HasPrefix(f[1], "$") {
			return f[1]
		}
	}
	return ""
}

// readTokenvaultPINs reads TPM2_PIN and FIDO2_PIN (KEY="value" lines).
func readTokenvaultPINs() map[string]string {
	pins := map[string]string{}
	data, err := os.ReadFile(tokenvaultConf)
	if err != nil {
		return pins
	}
	for _, line := range strings.Split(string(data), "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
		if ok && (k == "TPM2_PIN" || k == "FIDO2_PIN") {
			pins[k] = strings.Trim(v, `"'`)
		}
	}
	return pins
}

func writeCanary(hash string, gid int) error {
	dir := filepath.Dir(duress.File)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	// root's umask on secureblue is 027: without this the directory is
	// 0750 root:root and the locker (group hardened-duress) can't reach the file.
	if err := os.Chmod(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".duress-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o640); err != nil {
		return err
	}
	if err := tmp.Chown(0, gid); err != nil {
		return err
	}
	if _, err := tmp.WriteString(hash + "\n"); err != nil {
		return err
	}
	if err := tmp.Sync(); err != nil {
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), duress.File)
}

func duressClear() error {
	err := os.Remove(duress.File)
	if errors.Is(err, os.ErrNotExist) {
		fmt.Fprintln(os.Stderr, "no canary set")
		return nil
	}
	if err == nil {
		fmt.Fprintln(os.Stderr, "canary removed")
	}
	return err
}

func duressStatus(name string) error {
	fi, err := os.Stat(duress.File)
	switch {
	case errors.Is(err, os.ErrNotExist):
		fmt.Println("canary: not set")
	case err != nil:
		fmt.Println("canary:", err)
	default:
		_, perr := duress.Load(duress.File)
		state := "set"
		if perr != nil {
			state = perr.Error()
		}
		fmt.Printf("canary: %s (%s, mode %o)\n", state, duress.File, fi.Mode().Perm())
		if di, err := os.Stat(filepath.Dir(duress.File)); err == nil && di.Mode().Perm()&0o001 == 0 {
			fmt.Printf("warning: %s is mode %o: the lock screen can't reach the canary (run duress set again)\n",
				filepath.Dir(duress.File), di.Mode().Perm())
		}
	}
	if name != "" {
		u, err := user.Lookup(name)
		grp, gerr := user.LookupGroup(duress.Group)
		if err == nil && gerr == nil {
			ids, _ := u.GroupIds()
			fmt.Printf("user %s in %s: %v\n", name, duress.Group, slices.Contains(ids, grp.Gid))
		}
	}
	out, _ := exec.Command("systemctl", "is-active", "hardened-unlock-duress.socket").Output()
	fmt.Printf("reset helper socket: %s\n", strings.TrimSpace(string(out)))
	return nil
}

// readSecret reads one line without echo from a terminal, or one plain line
// from stdin when it isn't one (scripted tests).
func readSecret(in *bufio.Reader, prompt string) ([]byte, error) {
	fd := int(os.Stdin.Fd())
	if term.IsTerminal(fd) {
		fmt.Fprint(os.Stderr, prompt)
		b, err := term.ReadPassword(fd)
		fmt.Fprintln(os.Stderr)
		return b, err
	}
	line, err := in.ReadBytes('\n')
	if err != nil && len(line) == 0 {
		return nil, fmt.Errorf("read canary: %w", err)
	}
	return bytes.TrimRight(line, "\r\n"), nil
}
