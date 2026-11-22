// Package wire speaks the vmgui wire protocol, version 1 (vmgui/PROTOCOL.md):
// the guest side of window transport for guests without Wayland.
package wire

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"sync"
	"unicode/utf8"
)

const (
	Magic      = 0x57474d56 // "VMGW"
	Version    = 1
	MaxPayload = 16<<20 + 16
	MaxSide    = 4096
	MaxWindows = 64
	MaxTitle   = 512
)

// Guest to host.
const (
	Hello uint16 = iota + 1
	Create
	Destroy
	Title
	Resize
	Damage
	Commit
)

// Host to guest.
const (
	Configure uint16 = iota + 0x81
	Close
	Focus
	Motion
	Button
	Axis
	Key
	Leave
)

// Event is one host-to-guest message.
type Event struct {
	Type   uint16
	Window uint32
	A, B   int32 // the payload's two words, where the type has them
}

// Conn is a guest connection. Writes are serialized; Next reads one event.
type Conn struct {
	rw  io.ReadWriter
	mu  sync.Mutex
	hdr [12]byte
}

// Dial starts the protocol on rw (a vsock stream) by sending HELLO.
func Dial(rw io.ReadWriter) (*Conn, error) {
	c := &Conn{rw: rw}
	var p [8]byte
	binary.LittleEndian.PutUint32(p[0:], Magic)
	binary.LittleEndian.PutUint32(p[4:], Version)
	return c, c.send(Hello, 0, p[:])
}

func (c *Conn) send(typ uint16, win uint32, parts ...[]byte) error {
	n := 0
	for _, p := range parts {
		n += len(p)
	}
	if n > MaxPayload {
		return fmt.Errorf("wire: payload %d too large", n)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	binary.LittleEndian.PutUint16(c.hdr[0:], typ)
	binary.LittleEndian.PutUint16(c.hdr[2:], 0)
	binary.LittleEndian.PutUint32(c.hdr[4:], win)
	binary.LittleEndian.PutUint32(c.hdr[8:], uint32(n))
	if _, err := c.rw.Write(c.hdr[:]); err != nil {
		return err
	}
	for _, p := range parts {
		if _, err := c.rw.Write(p); err != nil {
			return err
		}
	}
	return nil
}

func size(w, h int) ([]byte, error) {
	if w < 1 || h < 1 || w > MaxSide || h > MaxSide {
		return nil, fmt.Errorf("wire: size %dx%d out of range", w, h)
	}
	var p [8]byte
	binary.LittleEndian.PutUint32(p[0:], uint32(w))
	binary.LittleEndian.PutUint32(p[4:], uint32(h))
	return p[:], nil
}

func (c *Conn) Create(win uint32, w, h int) error {
	p, err := size(w, h)
	if err != nil {
		return err
	}
	return c.send(Create, win, p)
}

func (c *Conn) Resize(win uint32, w, h int) error {
	p, err := size(w, h)
	if err != nil {
		return err
	}
	return c.send(Resize, win, p)
}

func (c *Conn) Destroy(win uint32) error { return c.send(Destroy, win) }
func (c *Conn) Commit(win uint32) error  { return c.send(Commit, win) }

// SetTitle sends at most MaxTitle bytes, cut on a UTF-8 boundary.
func (c *Conn) SetTitle(win uint32, title string) error {
	b := []byte(title)
	if len(b) > MaxTitle {
		b = b[:MaxTitle]
		for len(b) > 0 && !utf8.Valid(b) {
			b = b[:len(b)-1]
		}
	}
	return c.send(Title, win, b)
}

// Damage sends the rectangle x,y,w,h of an XRGB8888 frame with the given stride.
func (c *Conn) Damage(win uint32, frame []byte, stride, x, y, w, h int) error {
	if w < 1 || h < 1 || w*h*4 > MaxPayload-16 {
		return fmt.Errorf("wire: damage %dx%d out of range", w, h)
	}
	var p [16]byte
	binary.LittleEndian.PutUint32(p[0:], uint32(x))
	binary.LittleEndian.PutUint32(p[4:], uint32(y))
	binary.LittleEndian.PutUint32(p[8:], uint32(w))
	binary.LittleEndian.PutUint32(p[12:], uint32(h))
	px := make([]byte, w*h*4)
	for r := 0; r < h; r++ {
		o := (y+r)*stride + x*4
		copy(px[r*w*4:(r+1)*w*4], frame[o:o+w*4])
	}
	return c.send(Damage, win, p[:], px)
}

// ErrProtocol is returned by Next for a malformed host message.
var ErrProtocol = errors.New("wire: bad host message")

// Next reads one host event.
func (c *Conn) Next() (Event, error) {
	var h [12]byte
	if _, err := io.ReadFull(c.rw, h[:]); err != nil {
		return Event{}, err
	}
	ev := Event{Type: binary.LittleEndian.Uint16(h[0:]), Window: binary.LittleEndian.Uint32(h[4:])}
	n := binary.LittleEndian.Uint32(h[8:])
	want := map[uint16]uint32{Configure: 8, Close: 0, Focus: 4, Motion: 8, Button: 8, Axis: 8, Key: 8, Leave: 0}
	if w, ok := want[ev.Type]; !ok || w != n || binary.LittleEndian.Uint16(h[2:]) != 0 {
		return ev, ErrProtocol
	}
	var p [8]byte
	if _, err := io.ReadFull(c.rw, p[:n]); err != nil {
		return ev, err
	}
	ev.A = int32(binary.LittleEndian.Uint32(p[0:]))
	ev.B = int32(binary.LittleEndian.Uint32(p[4:]))
	return ev, nil
}
