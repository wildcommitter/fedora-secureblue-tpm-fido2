//go:build !duresstest

package duress

import (
	"fmt"
	"net"
	"time"
)

// Trigger asks the root helper to hard-reset the machine. It returns only
// if the request couldn't be delivered; on success the machine resets
// before the call returns.
func Trigger() error {
	c, err := net.DialTimeout("unix", Socket, 2*time.Second)
	if err != nil {
		return fmt.Errorf("duress: reach reset helper: %w", err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := c.Write([]byte{Request}); err != nil {
		return fmt.Errorf("duress: send reset request: %w", err)
	}
	// The helper never answers: it resets. Wait for the reset; a read
	// that returns means the helper closed without resetting.
	var b [1]byte
	_, err = c.Read(b[:])
	return fmt.Errorf("duress: reset helper returned without resetting (%v)", err)
}
