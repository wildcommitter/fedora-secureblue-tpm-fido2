package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"strings"

	"hardened-unlock/internal/u2fmap"
)

const keyUsage = `usage: hardened-unlock key add|status [--user NAME]   (as root)
  add     register the plugged-in FIDO2 key for the lock screen: asks its PIN,
          then a touch (pamu2fcfg), and adds it to ` + u2fmap.File + `
  status  show how many keys are registered
NAME defaults to the user who ran run0/sudo. Plug in only the key to register.
`

// keyCLI implements `hardened-unlock key ...`.
func keyCLI(args []string) int {
	if len(args) == 0 {
		fmt.Fprint(os.Stderr, keyUsage)
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
		fmt.Fprint(os.Stderr, keyUsage)
		return 2
	}
	if os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "hardened-unlock key: run as root (run0 hardened-unlock key ...)")
		return 1
	}
	if name == "" {
		fmt.Fprintln(os.Stderr, "hardened-unlock key: no user: pass --user NAME")
		return 1
	}
	if _, err := user.Lookup(name); err != nil {
		fmt.Fprintln(os.Stderr, "hardened-unlock key:", err)
		return 1
	}
	var err error
	switch cmd {
	case "add":
		err = keyAdd(name)
	case "status":
		err = keyStatus(name)
	default:
		fmt.Fprint(os.Stderr, keyUsage)
		return 2
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "hardened-unlock key:", err)
		return 1
	}
	return 0
}

func keyAdd(name string) error {
	data, err := os.ReadFile(u2fmap.File)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	// -N: the credential requires the PIN (pinverification=1). -n: no
	// username, so the output can be appended to an existing line. pamu2fcfg
	// asks the PIN on the terminal and prompts for the touch itself.
	c := exec.Command("pamu2fcfg", "-u", name, "-o", u2fmap.Origin, "-i", u2fmap.Origin, "-N", "-n")
	c.Stdin, c.Stderr = os.Stdin, os.Stderr
	out, err := c.Output()
	if err != nil {
		return fmt.Errorf("pamu2fcfg: %w", err)
	}
	updated, err := u2fmap.Add(data, name, string(out))
	if err != nil {
		return err
	}
	if err := u2fmap.Write(u2fmap.File, updated); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "key added for %s (%d registered) in %s\n", name, u2fmap.Count(updated, name), u2fmap.File)
	return nil
}

func keyStatus(name string) error {
	data, err := os.ReadFile(u2fmap.File)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	n := u2fmap.Count(data, name)
	fmt.Printf("keys for %s: %d of %d (%s)\n", name, n, u2fmap.MaxDevices, u2fmap.File)
	if n == 0 {
		fmt.Println(strings.TrimSpace(noKeyMessage))
	}
	return nil
}
