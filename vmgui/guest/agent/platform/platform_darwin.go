package platform

// macOS: windows from CGWindowListCopyWindowInfo (layer 0, on screen), captured
// with CGWindowListCreateImage at nominal resolution (points, so host pixels
// map 1:1 to the pointer) and drawn into a BGRX bitmap context, which is
// XRGB8888. Input goes in with CGEventPost. Needs Screen Recording and
// Accessibility for vmgui-agent in System Settings > Privacy & Security.
//
// No cgo: CoreGraphics and libc are called through purego, so this builds on
// Linux without an Apple SDK. CGWindowListCreateImage is deprecated since
// macOS 14 in favor of ScreenCaptureKit; if Apple removes it, this file needs
// a ScreenCaptureKit port. Close and resize need the Accessibility API and are
// not implemented yet: the window's own controls still work.

import (
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
	"unsafe"

	"github.com/ebitengine/purego"
	"github.com/ebitengine/purego/objc"
)

type cgPoint struct{ X, Y float64 }
type cgRect struct {
	Origin cgPoint
	W, H   float64
}

var (
	cfArrayGetCount         func(arr uintptr) int
	cfArrayGetValueAtIndex  func(arr uintptr, i int) uintptr
	cfDictionaryGetValue    func(d, key uintptr) uintptr
	cfNumberGetValue        func(n uintptr, typ int, out *int64) bool
	cfStringGetCString      func(s uintptr, buf *byte, size int, enc uint32) bool
	cfRelease               func(obj uintptr)
	cgWindowListCopyInfo    func(opt, rel uint32) uintptr
	cgWindowListCreateImage func(r cgRect, opt, wid, imgOpt uint32) uintptr
	cgRectFromDict          func(d uintptr, r *cgRect) bool
	cgImageGetWidth         func(img uintptr) int
	cgImageGetHeight        func(img uintptr) int
	cgImageRelease          func(img uintptr)
	cgColorSpaceDeviceRGB   func() uintptr
	cgColorSpaceRelease     func(cs uintptr)
	cgBitmapContextCreate   func(data unsafe.Pointer, w, h, bpc, bpr int, cs uintptr, info uint32) uintptr
	cgContextDrawImage      func(ctx uintptr, r cgRect, img uintptr)
	cgContextRelease        func(ctx uintptr)
	cgEventCreateMouse      func(src uintptr, typ uint32, at cgPoint, button uint32) uintptr
	cgEventCreateKey        func(src uintptr, key uint16, down bool) uintptr
	cgEventCreateScroll2    func(src uintptr, units uint32, count uint32, w1, w2, w3 int32) uintptr
	cgEventSetFlags         func(ev uintptr, flags uint64)
	cgEventPost             func(tap uint32, ev uintptr)
	libcSocket              func(domain, typ, proto int32) int32
	libcConnect             func(fd int32, sa unsafe.Pointer, n uint32) int32

	kNumber, kLayer, kBounds, kName, kOwner, kPID uintptr
	loadErr                                       error
	loadOnce                                      sync.Once
)

func load() error {
	loadOnce.Do(func() {
		cf, err := purego.Dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", purego.RTLD_NOW|purego.RTLD_GLOBAL)
		if err != nil {
			loadErr = err
			return
		}
		cg, err := purego.Dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", purego.RTLD_NOW|purego.RTLD_GLOBAL)
		if err != nil {
			loadErr = err
			return
		}
		libc, err := purego.Dlopen("/usr/lib/libSystem.B.dylib", purego.RTLD_NOW|purego.RTLD_GLOBAL)
		if err != nil {
			loadErr = err
			return
		}
		purego.Dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", purego.RTLD_NOW|purego.RTLD_GLOBAL)
		for _, f := range []struct {
			fn   any
			lib  uintptr
			name string
		}{
			{&cfArrayGetCount, cf, "CFArrayGetCount"}, {&cfArrayGetValueAtIndex, cf, "CFArrayGetValueAtIndex"},
			{&cfDictionaryGetValue, cf, "CFDictionaryGetValue"}, {&cfNumberGetValue, cf, "CFNumberGetValue"},
			{&cfStringGetCString, cf, "CFStringGetCString"}, {&cfRelease, cf, "CFRelease"},
			{&cgWindowListCopyInfo, cg, "CGWindowListCopyWindowInfo"},
			{&cgWindowListCreateImage, cg, "CGWindowListCreateImage"},
			{&cgRectFromDict, cg, "CGRectMakeWithDictionaryRepresentation"},
			{&cgImageGetWidth, cg, "CGImageGetWidth"}, {&cgImageGetHeight, cg, "CGImageGetHeight"},
			{&cgImageRelease, cg, "CGImageRelease"}, {&cgColorSpaceDeviceRGB, cg, "CGColorSpaceCreateDeviceRGB"},
			{&cgColorSpaceRelease, cg, "CGColorSpaceRelease"}, {&cgBitmapContextCreate, cg, "CGBitmapContextCreate"},
			{&cgContextDrawImage, cg, "CGContextDrawImage"}, {&cgContextRelease, cg, "CGContextRelease"},
			{&cgEventCreateMouse, cg, "CGEventCreateMouseEvent"}, {&cgEventCreateKey, cg, "CGEventCreateKeyboardEvent"},
			{&cgEventCreateScroll2, cg, "CGEventCreateScrollWheelEvent2"},
			{&cgEventSetFlags, cg, "CGEventSetFlags"}, {&cgEventPost, cg, "CGEventPost"},
			{&libcSocket, libc, "socket"}, {&libcConnect, libc, "connect"},
		} {
			purego.RegisterLibFunc(f.fn, f.lib, f.name)
		}
		key := func(name string) uintptr {
			p, err := purego.Dlsym(cg, name)
			if err != nil {
				loadErr = err
				return 0
			}
			return **(**uintptr)(unsafe.Pointer(&p)) // p is the address of a CFStringRef global
		}
		kNumber, kLayer, kBounds = key("kCGWindowNumber"), key("kCGWindowLayer"), key("kCGWindowBounds")
		kName, kOwner, kPID = key("kCGWindowName"), key("kCGWindowOwnerName"), key("kCGWindowOwnerPID")
	})
	return loadErr
}

func cfInt(d, k uintptr) (int64, bool) {
	v := cfDictionaryGetValue(d, k)
	var n int64
	return n, v != 0 && cfNumberGetValue(v, 4, &n) // kCFNumberSInt64Type
}

func cfString(d, k uintptr) string {
	v := cfDictionaryGetValue(d, k)
	if v == 0 {
		return ""
	}
	buf := make([]byte, 1024)
	if !cfStringGetCString(v, &buf[0], len(buf), 0x08000100) { // kCFStringEncodingUTF8
		return ""
	}
	for i, c := range buf {
		if c == 0 {
			return string(buf[:i])
		}
	}
	return ""
}

type quartz struct {
	mu      sync.Mutex
	bounds  map[uint32]cgRect
	pids    map[uint32]int64
	last    map[uint32]cgPoint // last pointer position, where a click lands
	buttons uint32             // pressed BTN_* bits (1 left, 2 right, 4 middle) for drag events
	flags   uint64             // modifier flags held down
	self    int64
}

func New() (Platform, error) {
	if err := load(); err != nil {
		return nil, fmt.Errorf("CoreGraphics: %w", err)
	}
	return &quartz{bounds: map[uint32]cgRect{}, pids: map[uint32]int64{}, last: map[uint32]cgPoint{},
		self: int64(os.Getpid())}, nil
}

func (q *quartz) Windows() ([]Window, error) {
	arr := cgWindowListCopyInfo(1|16, 0) // OnScreenOnly | ExcludeDesktopElements
	if arr == 0 {
		return nil, errors.New("CGWindowListCopyWindowInfo failed")
	}
	defer cfRelease(arr)
	var list []Window
	bounds, pids := map[uint32]cgRect{}, map[uint32]int64{}
	for i := 0; i < cfArrayGetCount(arr); i++ {
		d := cfArrayGetValueAtIndex(arr, i)
		layer, _ := cfInt(d, kLayer)
		num, ok := cfInt(d, kNumber)
		pid, _ := cfInt(d, kPID)
		var r cgRect
		if layer != 0 || !ok || num <= 0 || pid == q.self || !cgRectFromDict(cfDictionaryGetValue(d, kBounds), &r) ||
			r.W < 40 || r.H < 40 {
			continue
		}
		title := cfString(d, kName) // empty without Screen Recording permission
		if owner := cfString(d, kOwner); title == "" {
			title = owner
		} else if owner != "" && owner != title {
			title = owner + ": " + title
		}
		id := uint32(num)
		bounds[id], pids[id] = r, pid
		list = append(list, Window{ID: id, Title: title, W: int(r.W), H: int(r.H)})
	}
	q.mu.Lock()
	q.bounds, q.pids = bounds, pids
	q.mu.Unlock()
	return list, nil
}

func (q *quartz) Capture(id uint32, w, h int, dst []byte) error {
	null := cgRect{Origin: cgPoint{X: posInf, Y: posInf}} // CGRectNull: the window's own bounds
	// IncludingWindow; BoundsIgnoreFraming | NominalResolution
	img := cgWindowListCreateImage(null, 8, id, 1|16)
	if img == 0 {
		return errors.New("window gone or no Screen Recording permission")
	}
	defer cgImageRelease(img)
	cs := cgColorSpaceDeviceRGB()
	defer cgColorSpaceRelease(cs)
	clear(dst)
	// kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little: B, G, R, X in memory.
	ctx := cgBitmapContextCreate(unsafe.Pointer(&dst[0]), w, h, 8, w*4, cs, 6|2<<12)
	if ctx == 0 {
		return errors.New("CGBitmapContextCreate failed")
	}
	defer cgContextRelease(ctx)
	iw, ih := float64(cgImageGetWidth(img)), float64(cgImageGetHeight(img))
	// Quartz's origin is bottom-left: draw at the top of the w x h context.
	cgContextDrawImage(ctx, cgRect{Origin: cgPoint{0, float64(h) - ih}, W: iw, H: ih}, img)
	return nil
}

var posInf = func() float64 { var z float64; return 1 / z }()

func (q *quartz) at(id uint32, x, y int) (cgPoint, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	r, ok := q.bounds[id]
	return cgPoint{r.Origin.X + float64(x), r.Origin.Y + float64(y)}, ok
}

func post(ev uintptr) {
	if ev != 0 {
		cgEventPost(0, ev) // kCGHIDEventTap
		cfRelease(ev)
	}
}

func (q *quartz) Motion(id uint32, x, y int) {
	p, ok := q.at(id, x, y)
	if !ok {
		return
	}
	q.mu.Lock()
	q.last[id] = p
	b := q.buttons
	q.mu.Unlock()
	typ, button := uint32(5), uint32(0) // MouseMoved
	switch {
	case b&1 != 0:
		typ = 6 // LeftMouseDragged
	case b&2 != 0:
		typ, button = 7, 1 // RightMouseDragged
	case b&4 != 0:
		typ, button = 27, 2 // OtherMouseDragged
	}
	post(cgEventCreateMouse(0, typ, p, button))
}

func (q *quartz) Button(id uint32, b uint32, pressed bool) {
	types := map[uint32][3]uint32{ // event type down, up; CGMouseButton
		BtnLeft: {1, 2, 0}, BtnRight: {3, 4, 1}, BtnMiddle: {25, 26, 2},
	}[b]
	bit := map[uint32]uint32{BtnLeft: 1, BtnRight: 2, BtnMiddle: 4}[b]
	if bit == 0 {
		return
	}
	q.mu.Lock()
	p := q.last[id]
	if pressed {
		q.buttons |= bit
	} else {
		q.buttons &^= bit
	}
	q.mu.Unlock()
	typ := types[1]
	if pressed {
		typ = types[0]
	}
	post(cgEventCreateMouse(0, typ, p, types[2]))
}

func (q *quartz) Axis(id uint32, axis uint32, v int32) {
	px := -v / 256 // Wayland positive is down/right; Quartz wheel1 positive is up
	if axis == 0 {
		post(cgEventCreateScroll2(0, 0, 2, px, 0, 0)) // kCGScrollEventUnitPixel
	} else {
		post(cgEventCreateScroll2(0, 0, 2, 0, -px, 0))
	}
}

// evdev keycode -> macOS virtual keycode (kVK_*, ANSI layout positions).
var macKeys = map[uint32]uint16{
	1: 0x35, 2: 0x12, 3: 0x13, 4: 0x14, 5: 0x15, 6: 0x17, 7: 0x16, 8: 0x1a, 9: 0x1c, 10: 0x19, 11: 0x1d,
	12: 0x1b, 13: 0x18, 14: 0x33, 15: 0x30, 16: 0x0c, 17: 0x0d, 18: 0x0e, 19: 0x0f, 20: 0x11, 21: 0x10,
	22: 0x20, 23: 0x22, 24: 0x1f, 25: 0x23, 26: 0x21, 27: 0x1e, 28: 0x24, 29: 0x3b, 30: 0x00, 31: 0x01,
	32: 0x02, 33: 0x03, 34: 0x05, 35: 0x04, 36: 0x26, 37: 0x28, 38: 0x25, 39: 0x29, 40: 0x27, 41: 0x32,
	42: 0x38, 43: 0x2a, 44: 0x06, 45: 0x07, 46: 0x08, 47: 0x09, 48: 0x0b, 49: 0x2d, 50: 0x2e, 51: 0x2b,
	52: 0x2f, 53: 0x2c, 54: 0x3c, 55: 0x43, 56: 0x3a, 57: 0x31, 58: 0x39, 59: 0x7a, 60: 0x78, 61: 0x63,
	62: 0x76, 63: 0x60, 64: 0x61, 65: 0x62, 66: 0x64, 67: 0x65, 68: 0x6d, 69: 0x47, 71: 0x59, 72: 0x5b,
	73: 0x5c, 74: 0x4e, 75: 0x56, 76: 0x57, 77: 0x58, 78: 0x45, 79: 0x53, 80: 0x54, 81: 0x55, 82: 0x52,
	83: 0x41, 86: 0x0a, 87: 0x67, 88: 0x6f, 96: 0x4c, 97: 0x3e, 98: 0x4b, 100: 0x3d, 102: 0x73, 103: 0x7e,
	104: 0x74, 105: 0x7b, 106: 0x7c, 107: 0x77, 108: 0x7d, 109: 0x79, 110: 0x72, 111: 0x75, 117: 0x51,
	125: 0x37, 126: 0x36,
}

// Modifier keys and their CGEventFlags: shift, control, option, command.
var modFlags = map[uint32]uint64{42: 0x20000, 54: 0x20000, 29: 0x40000, 97: 0x40000,
	56: 0x80000, 100: 0x80000, 125: 0x100000, 126: 0x100000}

func (q *quartz) Key(id uint32, k uint32, pressed bool) {
	code, ok := macKeys[k]
	if !ok {
		return
	}
	q.mu.Lock()
	if f := modFlags[k]; f != 0 {
		if pressed {
			q.flags |= f
		} else {
			q.flags &^= f
		}
	}
	flags := q.flags
	q.mu.Unlock()
	ev := cgEventCreateKey(0, code, pressed)
	if ev != 0 {
		cgEventSetFlags(ev, flags)
	}
	post(ev)
}

// Focus brings the window's app to the front (NSRunningApplication).
func (q *quartz) Focus(id uint32) {
	q.mu.Lock()
	pid, ok := q.pids[id]
	q.mu.Unlock()
	if !ok {
		return
	}
	app := objc.ID(objc.GetClass("NSRunningApplication")).Send(
		objc.RegisterName("runningApplicationWithProcessIdentifier:"), int32(pid))
	if app != 0 {
		app.Send(objc.RegisterName("activateWithOptions:"), uint(0))
	}
}

func (q *quartz) Close(id uint32) {
	fmt.Fprintln(os.Stderr, "vmgui-agent: close is not implemented on macOS yet")
}
func (q *quartz) Resize(id uint32, w, h int) {}

// --- AF_VSOCK (Virtualization.framework guests; see the README for QEMU) ---

func LocalCID() (uint32, error) {
	return 0, errors.New("no local-CID query on macOS")
}

func DialHost(cid, port uint32) (io.ReadWriteCloser, error) {
	if err := load(); err != nil {
		return nil, err
	}
	const afVsock = 40
	fd := libcSocket(afVsock, 1, 0) // SOCK_STREAM
	if fd < 0 {
		return nil, errors.New("socket(AF_VSOCK) failed: no vsock device in this VM")
	}
	// struct sockaddr_vm: len, family, reserved, port, cid.
	sa := struct {
		length, family uint8
		reserved       uint16
		port, cid      uint32
	}{length: 12, family: afVsock, port: port, cid: cid}
	f := os.NewFile(uintptr(fd), "vsock")
	if libcConnect(fd, unsafe.Pointer(&sa), 12) != 0 {
		f.Close()
		return nil, fmt.Errorf("connect to vsock %d:%d failed", cid, port)
	}
	return f, nil
}
