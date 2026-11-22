package platform

// Windows 11: top-level windows from EnumWindows, captured with PrintWindow
// (PW_RENDERFULLCONTENT, so occluded windows and DWM content render too) into a
// 32-bit top-down DIB, which is already XRGB8888. Input goes in with SendInput:
// keys as set-1 scancodes (evdev 1..88 are the same numbers), the pointer in
// absolute virtual-desktop coordinates. The target window is brought to the
// front before a click or a key, because SendInput hits whatever is on top.
// vsock is virtio-win's viosock: its Winsock provider has no fixed address
// family, so it is looked up by name.

import (
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"syscall"
	"unsafe"
)

var (
	user32   = syscall.NewLazyDLL("user32.dll")
	gdi32    = syscall.NewLazyDLL("gdi32.dll")
	dwmapi   = syscall.NewLazyDLL("dwmapi.dll")
	ws2      = syscall.NewLazyDLL("ws2_32.dll")
	pEnum    = user32.NewProc("EnumWindows")
	pVisible = user32.NewProc("IsWindowVisible")
	pIconic  = user32.NewProc("IsIconic")
	pIsWin   = user32.NewProc("IsWindow")
	pLongPtr = user32.NewProc("GetWindowLongPtrW")
	pOwner   = user32.NewProc("GetWindow")
	pTextLen = user32.NewProc("GetWindowTextLengthW")
	pText    = user32.NewProc("GetWindowTextW")
	pRect    = user32.NewProc("GetWindowRect")
	pGetDC   = user32.NewProc("GetDC")
	pRelDC   = user32.NewProc("ReleaseDC")
	pPrint   = user32.NewProc("PrintWindow")
	pFore    = user32.NewProc("SetForegroundWindow")
	pTop     = user32.NewProc("BringWindowToTop")
	pInput   = user32.NewProc("SendInput")
	pPost    = user32.NewProc("PostMessageW")
	pPos     = user32.NewProc("SetWindowPos")
	pMetric  = user32.NewProc("GetSystemMetrics")
	pDpi     = user32.NewProc("SetProcessDpiAwarenessContext")
	pMemDC   = gdi32.NewProc("CreateCompatibleDC")
	pDIB     = gdi32.NewProc("CreateDIBSection")
	pSelect  = gdi32.NewProc("SelectObject")
	pDelObj  = gdi32.NewProc("DeleteObject")
	pDelDC   = gdi32.NewProc("DeleteDC")
	pDwmAttr = dwmapi.NewProc("DwmGetWindowAttribute")
	pConnect = ws2.NewProc("connect")
)

const (
	gwlExStyle          = ^uintptr(19) // -20
	wsExToolWindow      = 0x80
	wsExNoActivate      = 0x08000000
	gwOwner             = 4
	dwmwaExtendedFrame  = 9
	dwmwaCloaked        = 14
	pwRenderFullContent = 2
	wmClose             = 0x0010
	swpNoMove           = 0x2
	swpNoZOrder         = 0x4
	swpNoActivate       = 0x10
)

type rect struct{ L, T, R, B int32 }

// frame is where a window's visible part (DWM extended frame) sits inside its
// GetWindowRect, which on Windows 10/11 includes invisible resize borders.
type frame struct{ full, vis rect }

type win32 struct {
	mu     sync.Mutex
	frames map[uint32]frame
}

func New() (Platform, error) {
	pDpi.Call(^uintptr(3)) // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 (-4): real pixels
	return &win32{frames: map[uint32]frame{}}, nil
}

func call(p *syscall.LazyProc, a ...uintptr) uintptr { r, _, _ := p.Call(a...); return r }

func frameOf(h uintptr) (frame, bool) {
	var f frame
	if call(pRect, h, uintptr(unsafe.Pointer(&f.full))) == 0 {
		return f, false
	}
	if call(pDwmAttr, h, dwmwaExtendedFrame, uintptr(unsafe.Pointer(&f.vis)), unsafe.Sizeof(f.vis)) != 0 {
		f.vis = f.full
	}
	return f, f.vis.R > f.vis.L && f.vis.B > f.vis.T
}

// enum collects one EnumWindows pass. NewCallback slots are never freed, so
// there is one callback for the process; Windows serializes on enumMu.
var (
	enumMu     sync.Mutex
	enumList   []Window
	enumFrames map[uint32]frame
	enumCB     = syscall.NewCallback(enumProc)
)

func enumProc(h, _ uintptr) uintptr {
	ex := call(pLongPtr, h, gwlExStyle)
	var cloaked uint32
	call(pDwmAttr, h, dwmwaCloaked, uintptr(unsafe.Pointer(&cloaked)), 4)
	if call(pVisible, h) == 0 || call(pIconic, h) != 0 || call(pOwner, h, gwOwner) != 0 ||
		ex&(wsExToolWindow|wsExNoActivate) != 0 || cloaked != 0 {
		return 1
	}
	n := call(pTextLen, h)
	if n == 0 {
		return 1
	}
	buf := make([]uint16, n+1)
	call(pText, h, uintptr(unsafe.Pointer(&buf[0])), n+1)
	f, ok := frameOf(h)
	if !ok {
		return 1
	}
	id := uint32(h) // HWNDs keep their meaning in 32 bits (WOW64 interop)
	enumFrames[id] = f
	enumList = append(enumList, Window{ID: id, Title: syscall.UTF16ToString(buf),
		W: int(f.vis.R - f.vis.L), H: int(f.vis.B - f.vis.T)})
	return 1
}

func (p *win32) Windows() ([]Window, error) {
	enumMu.Lock()
	enumList, enumFrames = nil, map[uint32]frame{}
	call(pEnum, enumCB, 0)
	list, frames := enumList, enumFrames
	enumMu.Unlock()
	p.mu.Lock()
	p.frames = frames
	p.mu.Unlock()
	return list, nil
}

type bitmapInfo struct {
	size                      uint32
	width, height             int32
	planes, bitCount          uint16
	compression, sizeImage    uint32
	xppm, yppm, used, import_ int32
}

func (p *win32) Capture(id uint32, w, h int, dst []byte) error {
	hw := uintptr(id)
	f, ok := frameOf(hw)
	if !ok {
		return errors.New("window gone")
	}
	fw, fh := int(f.full.R-f.full.L), int(f.full.B-f.full.T)
	ox, oy := int(f.vis.L-f.full.L), int(f.vis.T-f.full.T)
	screen := call(pGetDC, 0)
	defer call(pRelDC, 0, screen)
	mem := call(pMemDC, screen)
	defer call(pDelDC, mem)
	bi := bitmapInfo{width: int32(fw), height: -int32(fh), planes: 1, bitCount: 32}
	bi.size = uint32(unsafe.Sizeof(bi))
	var bits unsafe.Pointer
	bmp := call(pDIB, mem, uintptr(unsafe.Pointer(&bi)), 0, uintptr(unsafe.Pointer(&bits)), 0, 0)
	if bmp == 0 {
		return errors.New("CreateDIBSection failed")
	}
	defer call(pDelObj, bmp)
	old := call(pSelect, mem, bmp)
	defer call(pSelect, mem, old)
	if call(pPrint, hw, mem, pwRenderFullContent) == 0 {
		return errors.New("PrintWindow failed")
	}
	src := unsafe.Slice((*byte)(bits), fw*fh*4)
	for y := 0; y < h; y++ {
		if oy+y >= fh {
			clear(dst[y*w*4:])
			break
		}
		o := (oy+y)*fw*4 + ox*4
		n := min(w, fw-ox) * 4
		copy(dst[y*w*4:y*w*4+n], src[o:o+n])
	}
	return nil
}

// SendInput. INPUT is a u32 type plus a union, 40 bytes on 64-bit Windows.
type input struct {
	typ uint32
	_   uint32
	u   [32]byte
}
type mouseInput struct {
	dx, dy            int32
	data, flags, time uint32
	extra             uintptr
}
type keyInput struct {
	vk, scan    uint16
	flags, time uint32
	extra       uintptr
}

func send(in input) { call(pInput, 1, uintptr(unsafe.Pointer(&in)), unsafe.Sizeof(in)) }

func mouse(m mouseInput) {
	in := input{typ: 0}
	*(*mouseInput)(unsafe.Pointer(&in.u)) = m
	send(in)
}

func (p *win32) front(id uint32) {
	call(pTop, uintptr(id))
	call(pFore, uintptr(id))
}

func (p *win32) Motion(id uint32, x, y int) {
	p.mu.Lock()
	f, ok := p.frames[id]
	p.mu.Unlock()
	if !ok {
		return
	}
	vx, vy := int(call(pMetric, 76)), int(call(pMetric, 77)) // SM_X/YVIRTUALSCREEN
	vw, vh := int(call(pMetric, 78)), int(call(pMetric, 79)) // SM_CX/CYVIRTUALSCREEN
	if vw < 2 || vh < 2 {
		return
	}
	sx, sy := int(f.vis.L)+x-vx, int(f.vis.T)+y-vy
	// MOUSEEVENTF_MOVE | ABSOLUTE | VIRTUALDESK
	mouse(mouseInput{dx: int32(sx * 65535 / (vw - 1)), dy: int32(sy * 65535 / (vh - 1)), flags: 0x0001 | 0x8000 | 0x4000})
}

func (p *win32) Button(id uint32, b uint32, pressed bool) {
	flags := map[uint32][2]uint32{BtnLeft: {0x2, 0x4}, BtnRight: {0x8, 0x10}, BtnMiddle: {0x20, 0x40}}[b]
	if flags[0] == 0 {
		return
	}
	if pressed {
		p.front(id)
		mouse(mouseInput{flags: flags[0]})
	} else {
		mouse(mouseInput{flags: flags[1]})
	}
}

func (p *win32) Axis(id uint32, axis uint32, v int32) {
	// Wayland: 10 px per wheel notch, positive is down/right. Windows: 120 per notch, positive is up/right.
	d := v * 12 / 256
	if axis == 0 {
		mouse(mouseInput{data: uint32(-d), flags: 0x0800}) // MOUSEEVENTF_WHEEL
	} else {
		mouse(mouseInput{data: uint32(d), flags: 0x1000}) // MOUSEEVENTF_HWHEEL
	}
}

// evdev codes past 88 that are E0-extended scancodes on a PC keyboard.
var extended = map[uint32]uint16{
	96: 0x1c, 97: 0x1d, 98: 0x35, 99: 0x37, 100: 0x38, 102: 0x47, 103: 0x48, 104: 0x49,
	105: 0x4b, 106: 0x4d, 107: 0x4f, 108: 0x50, 109: 0x51, 110: 0x52, 111: 0x53,
	125: 0x5b, 126: 0x5c, 127: 0x5d,
}

func (p *win32) Key(id uint32, k uint32, pressed bool) {
	ki := keyInput{flags: 0x8} // KEYEVENTF_SCANCODE
	switch {
	case k >= 1 && k <= 88 && k != 84 && k != 85:
		ki.scan = uint16(k)
	case extended[k] != 0:
		ki.scan, ki.flags = extended[k], ki.flags|0x1 // KEYEVENTF_EXTENDEDKEY
	default:
		return
	}
	if !pressed {
		ki.flags |= 0x2 // KEYEVENTF_KEYUP
	}
	in := input{typ: 1}
	*(*keyInput)(unsafe.Pointer(&in.u)) = ki
	send(in)
}

func (p *win32) Focus(id uint32) { p.front(id) }
func (p *win32) Close(id uint32) { call(pPost, uintptr(id), wmClose, 0, 0) }

func (p *win32) Resize(id uint32, w, h int) {
	f, ok := frameOf(uintptr(id))
	if !ok {
		return
	}
	dw := int(f.full.R-f.full.L) - int(f.vis.R-f.vis.L)
	dh := int(f.full.B-f.full.T) - int(f.vis.B-f.vis.T)
	call(pPos, uintptr(id), 0, 0, 0, uintptr(w+dw), uintptr(h+dh), swpNoMove|swpNoZOrder|swpNoActivate)
}

// --- viosock ---

func LocalCID() (uint32, error) {
	return 0, errors.New("viosock has no local-CID query here")
}

func viosockFamily() (int32, error) {
	var d syscall.WSAData
	if err := syscall.WSAStartup(0x0202, &d); err != nil {
		return 0, err
	}
	var size uint32
	syscall.WSAEnumProtocols(nil, nil, &size)
	if size == 0 {
		return 0, errors.New("WSAEnumProtocols: no providers")
	}
	buf := make([]syscall.WSAProtocolInfo, size/uint32(unsafe.Sizeof(syscall.WSAProtocolInfo{}))+1)
	n, err := syscall.WSAEnumProtocols(nil, &buf[0], &size)
	if err != nil {
		return 0, err
	}
	for _, pi := range buf[:n] {
		if strings.Contains(strings.ToUpper(syscall.UTF16ToString(pi.ProtocolName[:])), "VIOSOCK") {
			return pi.AddressFamily, nil
		}
	}
	return 0, errors.New("no viosock Winsock provider (install virtio-win's viosock driver)")
}

type sock struct{ h syscall.Handle }

func (s sock) Read(b []byte) (int, error) {
	if len(b) == 0 {
		return 0, nil
	}
	buf := syscall.WSABuf{Len: uint32(len(b)), Buf: &b[0]}
	var n, flags uint32
	if err := syscall.WSARecv(s.h, &buf, 1, &n, &flags, nil, nil); err != nil {
		return 0, err
	}
	if n == 0 {
		return 0, io.EOF
	}
	return int(n), nil
}

func (s sock) Write(b []byte) (int, error) {
	for done := 0; done < len(b); {
		buf := syscall.WSABuf{Len: uint32(len(b) - done), Buf: &b[done]}
		var n uint32
		if err := syscall.WSASend(s.h, &buf, 1, &n, 0, nil, nil); err != nil {
			return done, err
		}
		done += int(n)
	}
	return len(b), nil
}

func (s sock) Close() error { return syscall.Closesocket(s.h) }

func DialHost(cid, port uint32) (io.ReadWriteCloser, error) {
	af, err := viosockFamily()
	if err != nil {
		return nil, err
	}
	h, err := syscall.Socket(int(af), syscall.SOCK_STREAM, 0)
	if err != nil {
		return nil, fmt.Errorf("viosock socket: %w", err)
	}
	// SOCKADDR_VM (vio_sockets.h): family, reserved, port, cid, 4 zero bytes.
	sa := struct {
		family, reserved uint16
		port, cid        uint32
		zero             [4]byte
	}{family: uint16(af), port: port, cid: cid}
	if r, _, e := pConnect.Call(uintptr(h), uintptr(unsafe.Pointer(&sa)), unsafe.Sizeof(sa)); r != 0 {
		syscall.Closesocket(h)
		return nil, fmt.Errorf("viosock connect: %v", e)
	}
	return sock{h}, nil
}
