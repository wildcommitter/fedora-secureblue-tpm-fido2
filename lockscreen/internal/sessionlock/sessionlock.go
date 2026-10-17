// Package sessionlock is a small cgo bridge to the GTK4 session lock API in
// gtk4-layer-shell (>= 1.2, Fedora: gtk4-layer-shell), which implements
// Wayland's ext-session-lock-v1 for GTK4 applications. There is no existing
// Go binding for it, so this wraps just the handful of C functions we need.
//
// (The older standalone libgtk-session-lock is GTK3-only and must not be
// linked into a GTK4 process.)
package sessionlock

/*
#cgo pkg-config: gtk4-layer-shell-0 gtk4
#include <gtk4-layer-shell/gtk4-session-lock.h>
#include <glib-object.h>
#include <stdint.h>
#include <stdlib.h>

extern void goSessionLockMonitor(GtkSessionLockInstance *self, GdkMonitor *monitor, gpointer user_data);
extern void goSessionLockLocked(GtkSessionLockInstance *self, gpointer user_data);
extern void goSessionLockFailed(GtkSessionLockInstance *self, gpointer user_data);
extern void goSessionLockUnlocked(GtkSessionLockInstance *self, gpointer user_data);

// The window arrives as gotk4's uintptr object address and becomes a pointer
// on the C side, which keeps go vet's unsafe.Pointer check meaningful.
static void assignWindow(GtkSessionLockInstance *lock, uintptr_t window, GdkMonitor *monitor) {
	gtk_session_lock_instance_assign_window_to_monitor(lock, (GtkWindow *)window, monitor);
}

static void connectSignals(GtkSessionLockInstance *lock, gpointer user_data) {
	g_signal_connect(lock, "monitor", G_CALLBACK(goSessionLockMonitor), user_data);
	g_signal_connect(lock, "locked", G_CALLBACK(goSessionLockLocked), user_data);
	g_signal_connect(lock, "failed", G_CALLBACK(goSessionLockFailed), user_data);
	g_signal_connect(lock, "unlocked", G_CALLBACK(goSessionLockUnlocked), user_data);
}
*/
import "C"

import (
	"runtime/cgo"
	"unsafe"

	coreglib "github.com/diamondburned/gotk4/pkg/core/glib"
)

// IsSupported reports whether the current Wayland compositor implements
// ext-session-lock-v1. May block briefly on first call for a roundtrip.
func IsSupported() bool {
	return C.gtk_session_lock_is_supported() != C.FALSE
}

// Monitor is a monitor handed to OnMonitor. It is only valid inside that
// callback.
type Monitor struct {
	ptr *C.GdkMonitor
}

// Lock is a session lock. Create one with New, set the callbacks, then call
// Lock. OnMonitor fires once per monitor present at lock time and again for
// every monitor plugged in while locked; give each one a fresh window with
// AssignWindow. Finish with Unlock after a successful authentication.
type Lock struct {
	ptr    *C.GtkSessionLockInstance
	handle cgo.Handle
	data   *C.uintptr_t // C copy of handle, the signals' user_data

	OnMonitor  func(m Monitor)
	OnLocked   func()
	OnFailed   func()
	OnUnlocked func()
}

// New creates a lock instance. Set the callbacks before calling Lock.
func New() *Lock {
	l := &Lock{ptr: C.gtk_session_lock_instance_new()}
	l.handle = cgo.NewHandle(l)
	// user_data is a pointer, so the handle travels in C memory rather than
	// as an integer disguised as a pointer. The lock lives until the
	// process exits, so neither is ever freed.
	l.data = (*C.uintptr_t)(C.malloc(C.size_t(unsafe.Sizeof(C.uintptr_t(0)))))
	*l.data = C.uintptr_t(l.handle)
	C.connectSignals(l.ptr, C.gpointer(unsafe.Pointer(l.data)))
	return l
}

// Lock asks the compositor to lock the session; OnLocked or OnFailed
// follows. It returns false if the attempt failed immediately.
func (l *Lock) Lock() bool {
	return C.gtk_session_lock_instance_lock(l.ptr) != C.FALSE
}

// AssignWindow shows the unrealized window `win` (typically a *gtk.Window)
// full-screen on `m` as a lock surface. The library unmaps and destroys the
// window when the lock ends or the monitor goes away.
func (l *Lock) AssignWindow(win coreglib.Objector, m Monitor) {
	C.assignWindow(l.ptr, C.uintptr_t(coreglib.InternObject(win).Native()), m.ptr)
}

// Unlock releases the session lock; OnUnlocked follows.
func (l *Lock) Unlock() {
	C.gtk_session_lock_instance_unlock(l.ptr)
}

func lockFrom(userData C.gpointer) *Lock {
	l, _ := cgo.Handle(*(*C.uintptr_t)(unsafe.Pointer(userData))).Value().(*Lock)
	return l
}

//export goSessionLockMonitor
func goSessionLockMonitor(self *C.GtkSessionLockInstance, monitor *C.GdkMonitor, userData C.gpointer) {
	if l := lockFrom(userData); l != nil && l.OnMonitor != nil {
		l.OnMonitor(Monitor{ptr: monitor})
	}
}

//export goSessionLockLocked
func goSessionLockLocked(self *C.GtkSessionLockInstance, userData C.gpointer) {
	if l := lockFrom(userData); l != nil && l.OnLocked != nil {
		l.OnLocked()
	}
}

//export goSessionLockFailed
func goSessionLockFailed(self *C.GtkSessionLockInstance, userData C.gpointer) {
	if l := lockFrom(userData); l != nil && l.OnFailed != nil {
		l.OnFailed()
	}
}

//export goSessionLockUnlocked
func goSessionLockUnlocked(self *C.GtkSessionLockInstance, userData C.gpointer) {
	if l := lockFrom(userData); l != nil && l.OnUnlocked != nil {
		l.OnUnlocked()
	}
}
