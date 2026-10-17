package pamauth

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
)

// Result is the terminal outcome of an authentication attempt.
type Result struct {
	Success bool
	Message string // failure reason, or empty on success
}

// Handler receives the PAM conversation. Both callbacks are called from the
// goroutine that called Authenticate, one at a time, in PAM's order.
type Handler struct {
	// Status gets every PAM_TEXT_INFO / PAM_ERROR_MSG message as it
	// arrives, e.g. pam_u2f's "Please touch the device." cue.
	Status func(message string, isError bool)

	// Prompt answers one PAM prompt, e.g. pam_unix's "Password: " or
	// pam_u2f's "Please enter the PIN: ". Each module in the stack asks
	// for its own secret, so a stack of two modules prompts twice. It may
	// block until the user has answered. Authenticate zeroes the returned
	// slice once it has been sent; an error aborts the attempt.
	Prompt func(prompt string, echo bool) ([]byte, error)
}

// Authenticate runs the PAM `service` for the current user by spawning a
// fresh copy of the running executable in helper mode (re-exec'd via
// /proc/self/exe) and speaking the frame protocol over a pipe. Running PAM
// in a dedicated freshly-exec'd process — rather than in-process — avoids
// known hazards of calling PAM from a process that already has other
// threads, an active glib main loop, or D-Bus connections open (some PAM
// modules, and NSS underneath pam_unix, are not safe to call from arbitrary
// multi-threaded state).
func Authenticate(service string, h Handler) (Result, error) {
	exe, err := os.Executable()
	if err != nil {
		return Result{}, fmt.Errorf("pamauth: resolve executable: %w", err)
	}

	cmd := exec.Command(exe, HelperSubcommand, service)
	cmd.Stderr = os.Stderr

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return Result{}, fmt.Errorf("pamauth: stdin pipe: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return Result{}, fmt.Errorf("pamauth: stdout pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return Result{}, fmt.Errorf("pamauth: start helper: %w", err)
	}

	result, readErr := converse(stdout, stdin, h)
	_ = stdin.Close()
	waitErr := cmd.Wait()

	if readErr != nil && readErr != io.EOF {
		return Result{}, fmt.Errorf("pamauth: talk to helper: %w", readErr)
	}
	if result == nil {
		reason := "authentication helper exited without a result"
		if waitErr != nil {
			reason = waitErr.Error()
		}
		return Result{Success: false, Message: reason}, nil
	}
	return *result, nil
}

// converse reads the helper's frames until a result, answering each prompt
// frame through h.Prompt.
func converse(r io.Reader, w io.Writer, h Handler) (*Result, error) {
	br := bufio.NewReader(r)
	for {
		typ, payload, err := readFrame(br)
		if err != nil {
			return nil, err
		}
		switch typ {
		case frameStatusInfo:
			if h.Status != nil {
				h.Status(string(payload), false)
			}
		case frameStatusError:
			if h.Status != nil {
				h.Status(string(payload), true)
			}
		case framePromptEchoOff, framePromptEchoOn:
			if h.Prompt == nil {
				return nil, fmt.Errorf("PAM asked %q but no prompt handler is set", payload)
			}
			answer, err := h.Prompt(string(payload), typ == framePromptEchoOn)
			if err != nil {
				zeroBytes(answer)
				return nil, err
			}
			err = writeFramedBytes(w, answer)
			zeroBytes(answer)
			if err != nil {
				return nil, err
			}
		case frameResultOK:
			return &Result{Success: true}, nil
		case frameResultFail:
			return &Result{Success: false, Message: string(payload)}, nil
		}
	}
}
