package platform

// Linux: no capture backend (Linux guests use waypipe). A demo window instead,
// so vmgui-wire and the agent can be tested end to end on vsock loopback: one
// window with a moving bar and a square at the last pointer position. Every
// host event is printed on stdout ("event key 30 1") for the e2e to check.

import (
	"fmt"
	"io"
	"os"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

const demoID = 1

type demo struct {
	mu     sync.Mutex
	w, h   int
	px, py int
	closed bool
	start  time.Time
}

func New() (Platform, error) { return &demo{w: 320, h: 200, px: -1, py: -1, start: time.Now()}, nil }

func (d *demo) Windows() ([]Window, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.closed {
		return nil, nil
	}
	return []Window{{ID: demoID, Title: "vmgui demo", W: d.w, H: d.h}}, nil
}

func (d *demo) Capture(id uint32, w, h int, dst []byte) error {
	d.mu.Lock()
	px, py := d.px, d.py
	d.mu.Unlock()
	bar := int(time.Since(d.start)/(50*time.Millisecond)) % w
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			o := (y*w + x) * 4
			b, g, r := byte(x*255/w), byte(y*255/h), byte(0x40)
			if x >= bar && x < bar+8 {
				b, g, r = 0xff, 0xff, 0xff
			}
			if px >= 0 && x >= px-5 && x <= px+5 && y >= py-5 && y <= py+5 {
				b, g, r = 0, 0, 0xff
			}
			dst[o], dst[o+1], dst[o+2], dst[o+3] = b, g, r, 0
		}
	}
	return nil
}

func event(format string, a ...any) { fmt.Fprintf(os.Stdout, "event "+format+"\n", a...) }

func (d *demo) Motion(id uint32, x, y int) {
	d.mu.Lock()
	d.px, d.py = x, y
	d.mu.Unlock()
	event("motion %d %d", x, y)
}

func (d *demo) Button(id uint32, b uint32, p bool) { event("button %#x %t", b, p) }
func (d *demo) Axis(id uint32, a uint32, v int32)  { event("axis %d %d", a, v) }
func (d *demo) Key(id uint32, k uint32, p bool)    { event("key %d %t", k, p) }
func (d *demo) Focus(id uint32)                    { event("focus %d", id) }

func (d *demo) Close(id uint32) {
	d.mu.Lock()
	d.closed = true
	d.mu.Unlock()
	event("close %d", id)
}

func (d *demo) Resize(id uint32, w, h int) {
	d.mu.Lock()
	d.w, d.h = w, h
	d.mu.Unlock()
	event("resize %d %d", w, h)
}

func LocalCID() (uint32, error) {
	f, err := os.Open("/dev/vsock")
	if err != nil {
		return 0, err
	}
	defer f.Close()
	return unix.IoctlGetUint32(int(f.Fd()), unix.IOCTL_VM_SOCKETS_GET_LOCAL_CID)
}

type vsock struct{ fd int }

func (v vsock) Read(b []byte) (int, error) {
	n, err := unix.Read(v.fd, b)
	if n == 0 && err == nil && len(b) > 0 {
		return 0, io.EOF
	}
	return max(n, 0), err
}
func (v vsock) Write(b []byte) (int, error) {
	for done := 0; done < len(b); {
		n, err := unix.Write(v.fd, b[done:])
		if err != nil {
			return done, err
		}
		done += n
	}
	return len(b), nil
}
func (v vsock) Close() error { return unix.Close(v.fd) }

func DialHost(cid, port uint32) (io.ReadWriteCloser, error) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	if err := unix.Connect(fd, &unix.SockaddrVM{CID: cid, Port: port}); err != nil {
		unix.Close(fd)
		return nil, err
	}
	return vsock{fd}, nil
}
