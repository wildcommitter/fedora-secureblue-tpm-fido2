// Command duress-reset is the root side of the lock screen's duress canary.
// systemd starts it from hardened-unlock-duress.socket (a unix socket that
// only the hardened-duress group may connect to) with CAP_SYS_BOOT as its
// only capability. A connection that sends the single request byte gets an
// immediate reboot(2) RESTART: no sync, no shutdown sequence. Any other
// input is dropped.
package main

import (
	"fmt"
	"net"
	"os"
	"strconv"
	"syscall"
	"time"
)

// request is the one byte that asks for the reset; it must equal
// duress.Request (checked by the test). Not imported, so this binary doesn't
// link libcrypt.
const request = 'R'

func main() {
	l, err := activationListener()
	if err != nil {
		fmt.Fprintln(os.Stderr, "duress-reset:", err)
		os.Exit(1)
	}
	serve(l, func() error {
		// Deliberately no sync(): the point is to stop now, not cleanly.
		return syscall.Reboot(syscall.LINUX_REBOOT_CMD_RESTART)
	})
}

// activationListener returns the one socket systemd passed (fd 3).
func activationListener() (net.Listener, error) {
	if os.Getenv("LISTEN_PID") != strconv.Itoa(os.Getpid()) || os.Getenv("LISTEN_FDS") != "1" {
		return nil, fmt.Errorf("not started by hardened-unlock-duress.socket")
	}
	f := os.NewFile(3, "duress.sock")
	l, err := net.FileListener(f)
	f.Close()
	return l, err
}

// serve handles one connection at a time until the listener fails.
func serve(l net.Listener, reset func() error) {
	for {
		c, err := l.Accept()
		if err != nil {
			fmt.Fprintln(os.Stderr, "duress-reset: accept:", err)
			return
		}
		if handle(c) {
			if err := reset(); err != nil {
				fmt.Fprintln(os.Stderr, "duress-reset: reboot:", err)
			}
		}
		c.Close()
	}
}

// handle reads the request and reports whether it asks for the reset.
func handle(c net.Conn) bool {
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	var b [2]byte
	n, _ := c.Read(b[:])
	if n == 1 && b[0] == request {
		return true
	}
	fmt.Fprintln(os.Stderr, "duress-reset: ignored a malformed request")
	return false
}
