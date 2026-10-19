// Command hardened-unlock is a Wayland screen locker for scroll (or any
// compositor implementing ext-session-lock-v1). It authenticates against the
// "hardened-unlock" PAM service, which is configured (see etc/pam.d/) to
// require both a FIDO2 security key with its client PIN and a touch (pam_u2f)
// and the account password. Unlike swaylock, it asks every PAM prompt
// separately, so the password and the key PIN can differ, and it shows
// PAM_TEXT_INFO/PAM_ERROR_MSG conversation messages (e.g. pam_u2f's "Please
// touch the device.") live instead of discarding them.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"syscall"

	"github.com/diamondburned/gotk4/pkg/core/glib"
	"github.com/diamondburned/gotk4/pkg/gdk/v4"
	"github.com/diamondburned/gotk4/pkg/gio/v2"
	"github.com/diamondburned/gotk4/pkg/gtk/v4"

	"hardened-unlock/internal/pamauth"
	"hardened-unlock/internal/sessionlock"
)

const (
	pamService    = "hardened-unlock"
	applicationID = "dev.hardenedunlock.Lock"

	// The PAM stack asks for the key PIN first, so text typed before Enter
	// answers that prompt. It is only used if the first prompt really
	// mentions initialPromptWord: typed as a PIN, a password would burn one
	// of the key's PIN retries, and the other way round it would count
	// against faillock.
	initialPrompt     = "Security key PIN"
	initialPromptWord = "pin"

	// readyFdEnv names the fd on which a child started by -f reports that
	// the session is locked.
	readyFdEnv = "HARDENED_UNLOCK_READY_FD"

	// debugEnv set to 1 logs every PAM prompt and status message (never an
	// answer) to stderr, for the e2e test and for troubleshooting.
	debugEnv = "HARDENED_UNLOCK_DEBUG"
)

var debug = os.Getenv(debugEnv) == "1"

func debugf(format string, args ...any) {
	if debug {
		fmt.Fprintf(os.Stderr, "hardened-unlock: "+format+"\n", args...)
	}
}

const css = `
window.lock-surface {
	background-color: rgba(15, 15, 20, 0.92);
}
box.lock-panel {
	background-color: rgba(30, 30, 38, 0.95);
	border-radius: 18px;
	padding: 36px;
}
label.lock-user {
	font-size: 20px;
	font-weight: 600;
	color: #eaeaf0;
}
label.lock-status {
	font-size: 13px;
	color: #a8a8b6;
	margin-top: 6px;
}
label.lock-status.error {
	color: #ff6b6b;
}
entry.lock-password {
	font-size: 16px;
	min-width: 260px;
	margin-top: 14px;
}
label.lock-prompt {
	font-size: 13px;
	color: #7c7c8a;
	margin-top: 10px;
}
`

func init() {
	// GTK/glib main-loop code must stay pinned to the OS thread it
	// initialized on.
	runtime.LockOSThread()
}

func main() {
	if len(os.Args) >= 2 && os.Args[1] == pamauth.HelperSubcommand {
		service := ""
		if len(os.Args) >= 3 {
			service = os.Args[2]
		}
		os.Exit(pamauth.RunHelper(service))
	}

	for _, arg := range os.Args[1:] {
		switch arg {
		case "-f", "--daemonize":
			os.Exit(daemonize())
		default:
			fmt.Fprintf(os.Stderr, "usage: hardened-unlock [-f]\n"+
				"  -f  return once the session is locked (for swayidle before-sleep)\n")
			os.Exit(2)
		}
	}

	if !sessionlock.IsSupported() {
		fmt.Fprintln(os.Stderr, "hardened-unlock: compositor does not support ext-session-lock-v1")
		os.Exit(1)
	}

	// Non-unique: a second locker (e.g. swayidle firing while already
	// locked) runs on its own, is refused by the compositor and exits,
	// instead of re-activating the first one over D-Bus.
	app := gtk.NewApplication(applicationID, gio.ApplicationNonUnique)
	ls := &lockScreen{app: app}
	app.ConnectActivate(func() { ls.onActivate() })
	os.Exit(app.Run(os.Args[:1]))
}

type lockScreen struct {
	app  *gtk.Application
	lock *sessionlock.Lock

	windows     []*gtk.Window
	interactive *gtk.Window // the window holding the entry; nil if none
	entry       *gtk.PasswordEntry
	prompt      *gtk.Label
	status      *gtk.Label

	authInFlight bool
	waiting      bool        // PAM is blocked on a prompt the user has to answer
	answers      chan []byte // main loop -> auth goroutine, one per prompt
}

func (ls *lockScreen) onActivate() {
	if ls.lock != nil {
		return
	}
	ls.app.Hold()

	provider := gtk.NewCSSProvider()
	provider.LoadFromString(css)
	if display := gdk.DisplayGetDefault(); display != nil {
		gtk.StyleContextAddProviderForDisplay(display, provider, gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
	}

	ls.lock = sessionlock.New()
	ls.lock.OnMonitor = ls.onMonitor
	ls.lock.OnLocked = func() {
		if ls.entry != nil {
			ls.entry.GrabFocus()
		}
		debugf("locked")
		reportLocked()
	}
	ls.lock.OnFailed = func() {
		fmt.Fprintln(os.Stderr, "hardened-unlock: session lock request was refused by the compositor")
		os.Exit(1)
	}
	// ::unlocked fires synchronously inside Unlock(), before the request
	// has reached the compositor, so it must not exit; exitAfterUnlock
	// does that once the request is through. It also fires if the
	// compositor drops the lock itself, with nothing left to guard.
	ls.lock.OnUnlocked = func() { glib.IdleAdd(exitAfterUnlock) }
	if !ls.lock.Lock() {
		fmt.Fprintln(os.Stderr, "hardened-unlock: could not start the session lock")
		os.Exit(1)
	}
}

// onMonitor gives every monitor a lock surface. The first one gets the
// password entry, the others just say "Locked".
func (ls *lockScreen) onMonitor(m sessionlock.Monitor) {
	win := gtk.NewWindow()
	win.AddCSSClass("lock-surface")
	if ls.interactive == nil {
		ls.makeInteractive(win)
	} else {
		win.SetChild(buildPassivePanel())
	}
	win.ConnectDestroy(func() { ls.onWindowGone(win) })
	ls.windows = append(ls.windows, win)
	ls.lock.AssignWindow(win, m)
}

// onWindowGone runs when a monitor is unplugged. If it took the entry with
// it, the entry moves to another monitor so the session can still be
// unlocked.
func (ls *lockScreen) onWindowGone(win *gtk.Window) {
	for i, w := range ls.windows {
		if w == win {
			ls.windows = append(ls.windows[:i], ls.windows[i+1:]...)
			break
		}
	}
	if ls.interactive != win {
		return
	}
	ls.interactive, ls.entry, ls.prompt, ls.status = nil, nil, nil, nil
	if len(ls.windows) > 0 {
		ls.makeInteractive(ls.windows[0])
		ls.entry.GrabFocus()
	}
}

func (ls *lockScreen) makeInteractive(win *gtk.Window) {
	win.SetChild(ls.buildInteractivePanel())
	ls.interactive = win
	ls.entry.SetSensitive(!ls.authInFlight || ls.waiting)
}

func (ls *lockScreen) buildInteractivePanel() *gtk.Box {
	outer := gtk.NewBox(gtk.OrientationVertical, 0)
	outer.SetHAlign(gtk.AlignCenter)
	outer.SetVAlign(gtk.AlignCenter)
	outer.SetHExpand(true)
	outer.SetVExpand(true)

	panel := gtk.NewBox(gtk.OrientationVertical, 0)
	panel.AddCSSClass("lock-panel")
	panel.SetHAlign(gtk.AlignCenter)

	userLabel := gtk.NewLabel(currentUsernameOrFallback())
	userLabel.AddCSSClass("lock-user")
	panel.Append(userLabel)

	prompt := gtk.NewLabel(initialPrompt)
	prompt.AddCSSClass("lock-prompt")
	prompt.SetXAlign(0)
	panel.Append(prompt)
	ls.prompt = prompt

	entry := gtk.NewPasswordEntry()
	entry.AddCSSClass("lock-password")
	entry.SetShowPeekIcon(true)
	entry.ConnectActivate(func() { ls.onEnter() })
	panel.Append(entry)
	ls.entry = entry

	status := gtk.NewLabel("Key PIN, touch, then password")
	status.AddCSSClass("lock-status")
	status.SetWrap(true)
	panel.Append(status)
	ls.status = status

	outer.Append(panel)
	return outer
}

func buildPassivePanel() *gtk.Box {
	outer := gtk.NewBox(gtk.OrientationVertical, 0)
	outer.SetHAlign(gtk.AlignCenter)
	outer.SetVAlign(gtk.AlignCenter)
	outer.SetHExpand(true)
	outer.SetVExpand(true)

	label := gtk.NewLabel("Locked")
	label.AddCSSClass("lock-user")
	outer.Append(label)
	return outer
}

func (ls *lockScreen) setStatus(message string, isError bool) {
	if ls.status == nil {
		return
	}
	ls.status.SetText(message)
	if isError {
		ls.status.AddCSSClass("error")
	} else {
		ls.status.RemoveCSSClass("error")
	}
}

func (ls *lockScreen) setPrompt(text string) {
	if ls.prompt != nil {
		ls.prompt.SetText(strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(text), ":")))
	}
}

// onEnter either starts an authentication (the typed text, if any, answers
// the first prompt if it is the expected PIN prompt) or answers the prompt
// PAM is waiting on.
func (ls *lockScreen) onEnter() {
	if ls.entry == nil {
		return
	}
	text := []byte(ls.entry.Text())
	ls.entry.SetText("")

	switch {
	case !ls.authInFlight:
		ls.authInFlight = true
		ls.answers = make(chan []byte, 1)
		ls.entry.SetSensitive(false)
		ls.setStatus("Authenticating…", false)
		go ls.runAuthentication(text, ls.answers)
	case ls.waiting:
		ls.waiting = false
		ls.entry.SetSensitive(false)
		ls.setStatus("Checking…", false)
		ls.answers <- text
	default:
		zero(text)
	}
}

// runAuthentication runs on its own goroutine; every UI change goes back to
// the main loop through glib.IdleAdd.
func (ls *lockScreen) runAuthentication(typed []byte, answers chan []byte) {
	h := pamauth.Handler{
		Status: func(message string, isError bool) {
			debugf("status error=%v: %s", isError, message)
			glib.IdleAdd(func() { ls.setStatus(message, isError) })
		},
		Prompt: func(prompt string, echo bool) ([]byte, error) {
			debugf("prompt: %s", prompt)
			if typed != nil {
				first := typed
				typed = nil
				if len(first) > 0 && promptAsks(prompt, initialPromptWord) {
					debugf("answered with the text typed before Enter")
					return first, nil
				}
				zero(first)
			}
			glib.IdleAdd(func() {
				ls.setPrompt(prompt)
				ls.setStatus("", false)
				ls.waiting = true
				if ls.entry != nil {
					ls.entry.SetSensitive(true)
					ls.entry.GrabFocus()
				}
			})
			return <-answers, nil
		},
	}

	result, err := pamauth.Authenticate(pamService, h)
	zero(typed)
	glib.IdleAdd(func() { ls.handleAuthResult(result, err) })
}

func (ls *lockScreen) handleAuthResult(result pamauth.Result, err error) {
	ls.authInFlight = false
	ls.waiting = false
	ls.setPrompt(initialPrompt)
	debugf("result success=%v message=%q err=%v", result.Success, result.Message, err)

	if err == nil && result.Success {
		ls.lock.Unlock()
		exitAfterUnlock()
	}

	message := result.Message
	if err != nil {
		message = "Internal error: " + err.Error()
	} else if message == "" {
		message = "Authentication failed"
	}
	if ls.entry != nil {
		ls.entry.SetSensitive(true)
		ls.entry.GrabFocus()
	}
	ls.setStatus(message, true)
}

// exitAfterUnlock exits once the unlock request has reached the compositor.
// A locker that exits before that counts as crashed, and the session stays
// locked (scroll shows a red screen).
func exitAfterUnlock() {
	if display := gdk.DisplayGetDefault(); display != nil {
		display.Flush()
		display.Sync()
	}
	debugf("unlocked")
	os.Exit(0)
}

// daemonize runs the locker as a detached child and returns once the child
// reports the session locked, like swaylock -f. swayidle -w waits for its
// before-sleep command, so this lets the machine suspend only after the
// screen is really locked, without waiting for the unlock.
func daemonize() int {
	exe, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, "hardened-unlock:", err)
		return 1
	}
	r, w, err := os.Pipe()
	if err != nil {
		fmt.Fprintln(os.Stderr, "hardened-unlock:", err)
		return 1
	}
	cmd := exec.Command(exe)
	cmd.Env = append(os.Environ(), readyFdEnv+"=3")
	cmd.ExtraFiles = []*os.File{w}
	// scroll starts the locker on a connection of its own (WAYLAND_SOCKET): the
	// only one that gets the session-lock protocol. exec passes only ExtraFiles,
	// so hand that fd on to the child, which is the one that connects.
	if s := os.Getenv("WAYLAND_SOCKET"); s != "" {
		fd, err := strconv.Atoi(s)
		if err != nil || fd < 0 {
			fmt.Fprintln(os.Stderr, "hardened-unlock: bad WAYLAND_SOCKET")
			return 1
		}
		cmd.ExtraFiles = append(cmd.ExtraFiles, os.NewFile(uintptr(fd), "wayland"))
		cmd.Env = append(cmd.Env, "WAYLAND_SOCKET=4") // the last value of a key wins
	}
	cmd.Stderr = os.Stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		fmt.Fprintln(os.Stderr, "hardened-unlock:", err)
		return 1
	}
	w.Close()
	var b [1]byte
	if n, _ := r.Read(b[:]); n == 1 {
		return 0
	}
	return 1 // the child exited without locking
}

// reportLocked tells a waiting daemonize parent that the session is locked.
func reportLocked() {
	if os.Getenv(readyFdEnv) != "3" {
		return
	}
	os.Unsetenv(readyFdEnv)
	f := os.NewFile(3, "ready")
	_, _ = f.Write([]byte{1})
	f.Close()
}

// promptAsks reports whether prompt contains word as a whole word, ignoring
// case ("Please enter the PIN: " asks "pin").
func promptAsks(prompt, word string) bool {
	for _, f := range strings.FieldsFunc(strings.ToLower(prompt), func(r rune) bool {
		return !('a' <= r && r <= 'z')
	}) {
		if f == word {
			return true
		}
	}
	return false
}

func zero(b []byte) {
	for i := range b {
		b[i] = 0
	}
}

func currentUsernameOrFallback() string {
	if name := os.Getenv("USER"); name != "" {
		return name
	}
	return "locked"
}
