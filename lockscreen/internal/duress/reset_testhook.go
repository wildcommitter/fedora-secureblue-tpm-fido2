//go:build duresstest

package duress

import (
	"errors"
	"os"
)

// TestMarkerEnv names the file that a duresstest build writes instead of
// resetting the machine. Only lockscreen/test/duress-e2e.sh uses this build.
const TestMarkerEnv = "HARDENED_UNLOCK_DURESS_MARKER"

// Trigger in a duresstest build writes the marker file and returns, so the
// e2e can check that the locker stays locked afterwards.
func Trigger() error {
	path := os.Getenv(TestMarkerEnv)
	if path == "" {
		return errors.New("duress: duresstest build without " + TestMarkerEnv)
	}
	return os.WriteFile(path, []byte("reset\n"), 0o644)
}
