// Package platform is the guest OS side of vmgui-agent: list top-level windows,
// capture them as XRGB8888, inject the host's input, and reach the host on vsock.
// One file per OS: windows (Win32 GDI + SendInput, viosock), darwin (CoreGraphics
// via purego, AF_VSOCK), linux (a demo window for the e2e, AF_VSOCK).
package platform

// Window is one top-level guest window. ID is stable for the window's life and
// nonzero (HWND on Windows, CGWindowID on macOS).
type Window struct {
	ID    uint32
	Title string
	W, H  int
}

// Platform is implemented per OS. Coordinates are window-local pixels.
type Platform interface {
	Windows() ([]Window, error)
	// Capture draws the window into dst (XRGB8888, stride w*4, w*h*4 bytes).
	Capture(id uint32, w, h int, dst []byte) error
	Motion(id uint32, x, y int)
	Button(id uint32, button uint32, pressed bool) // Linux BTN_* codes
	Axis(id uint32, axis uint32, value int32)      // 1/256 px; axis 0 vertical
	Key(id uint32, evdev uint32, pressed bool)     // Linux evdev keycode
	Focus(id uint32)
	Close(id uint32)
	Resize(id uint32, w, h int)
}

// Linux input codes the backends map from.
const (
	BtnLeft   = 0x110
	BtnRight  = 0x111
	BtnMiddle = 0x112
)
