// Command authtest exercises the "hardened-unlock" PAM stack from a normal
// terminal, without ever touching Wayland or locking the screen. Use it to
// validate the pam_unix + pam_u2f stack (and watch the status messages that
// would otherwise only flash by in the real lock screen) before trusting the
// GUI locker.
//
// Every PAM prompt is shown and read separately. Secret prompts are read
// without echo from the terminal, or one line each from stdin if stdin is
// not a terminal (for scripted tests).
package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"

	"golang.org/x/term"

	"hardened-unlock/internal/pamauth"
)

const pamService = "hardened-unlock"

func main() {
	if len(os.Args) >= 2 && os.Args[1] == pamauth.HelperSubcommand {
		service := ""
		if len(os.Args) >= 3 {
			service = os.Args[2]
		}
		os.Exit(pamauth.RunHelper(service))
	}

	service := pamService
	if len(os.Args) >= 2 {
		service = os.Args[1]
	}

	stdinFd := int(os.Stdin.Fd())
	isTerm := term.IsTerminal(stdinFd)
	lines := bufio.NewReader(os.Stdin)

	fmt.Println("Waiting on PAM (touch your security key when it blinks)…")

	result, authErr := pamauth.Authenticate(service, pamauth.Handler{
		Status: func(msg string, isError bool) {
			if isError {
				fmt.Fprintln(os.Stderr, "! "+msg)
			} else {
				fmt.Println("> " + msg)
			}
		},
		Prompt: func(prompt string, echo bool) ([]byte, error) {
			fmt.Print("? " + strings.TrimRight(prompt, " ") + " ")
			if !isTerm {
				line, err := lines.ReadString('\n')
				fmt.Println()
				return []byte(strings.TrimRight(line, "\r\n")), err
			}
			if echo {
				line, err := lines.ReadString('\n')
				return []byte(strings.TrimRight(line, "\r\n")), err
			}
			answer, err := term.ReadPassword(stdinFd)
			fmt.Println()
			return answer, err
		},
	})

	if authErr != nil {
		fmt.Fprintln(os.Stderr, "error:", authErr)
		os.Exit(2)
	}
	if !result.Success {
		fmt.Fprintln(os.Stderr, "FAILED:", result.Message)
		os.Exit(1)
	}
	fmt.Println("OK — every factor in the stack verified.")
}
