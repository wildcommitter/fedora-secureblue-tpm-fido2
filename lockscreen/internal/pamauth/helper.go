package pamauth

import (
	"bufio"
	"os"
	"os/user"

	pam "github.com/msteinert/pam/v2"
)

// HelperSubcommand is the hidden os.Args[1] value that switches the binary
// into helper mode. It must never be reachable from the lock screen's own
// UI/argument parsing.
const HelperSubcommand = "__pamauth_helper__"

// RunHelper performs the actual PAM conversation for `service` against the
// current user. Every prompt is sent to the parent as a frame on stdout and
// answered by the parent on stdin (one length-prefixed answer per prompt);
// status messages and the result are streamed as frames too. It never
// touches GTK, glib, or any other subsystem the parent process has
// initialized, so it is safe to run in a freshly exec'd child regardless of
// what state the parent's threads were in when it forked.
//
// Exit code: 0 on success, 1 on a clean authentication failure, 2 on a
// protocol/setup error.
func RunHelper(service string) int {
	if service == "" {
		return 2
	}

	u, err := user.Current()
	if err != nil || u.Username == "" {
		return 2
	}

	in := bufio.NewReader(os.Stdin)
	out := bufio.NewWriter(os.Stdout)

	ask := func(typ byte, msg string) (string, error) {
		if err := writeFrame(out, typ, []byte(msg)); err != nil {
			return "", err
		}
		if err := out.Flush(); err != nil {
			return "", err
		}
		answer, err := readFramedBytes(in)
		if err != nil {
			return "", err
		}
		defer zeroBytes(answer)
		// pam's ConversationFunc is string-based, so this copy can't be
		// avoided or wiped afterwards; it's owned by cgo/PAM once returned.
		return string(answer), nil
	}

	conv := func(style pam.Style, msg string) (string, error) {
		switch style {
		case pam.PromptEchoOff:
			return ask(framePromptEchoOff, msg)
		case pam.PromptEchoOn:
			return ask(framePromptEchoOn, msg)
		case pam.TextInfo:
			_ = writeFrame(out, frameStatusInfo, []byte(msg))
			_ = out.Flush()
			return "", nil
		case pam.ErrorMsg:
			_ = writeFrame(out, frameStatusError, []byte(msg))
			_ = out.Flush()
			return "", nil
		default:
			return "", nil
		}
	}

	t, err := pam.StartFunc(service, u.Username, conv)
	if err != nil {
		_ = writeFrame(out, frameResultFail, []byte(err.Error()))
		_ = out.Flush()
		return 1
	}
	defer t.End()

	authErr := t.Authenticate(0)
	if authErr == nil {
		// An unprivileged caller can't read /etc/shadow for the account
		// stack, so ignore ErrAuthinfoUnavail; Authenticate already proved
		// identity.
		if acctErr := t.AcctMgmt(0); acctErr != nil && acctErr != pam.ErrAuthinfoUnavail {
			authErr = acctErr
		}
	}

	if authErr != nil {
		_ = writeFrame(out, frameResultFail, []byte(authErr.Error()))
		_ = out.Flush()
		return 1
	}

	_ = writeFrame(out, frameResultOK, nil)
	_ = out.Flush()
	return 0
}
