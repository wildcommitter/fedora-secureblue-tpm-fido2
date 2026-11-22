package wire

import (
	"bytes"
	"encoding/binary"
	"strings"
	"testing"
	"unicode/utf8"
)

type pipe struct{ in, out bytes.Buffer }

func (p *pipe) Read(b []byte) (int, error)  { return p.in.Read(b) }
func (p *pipe) Write(b []byte) (int, error) { return p.out.Write(b) }

func header(t *testing.T, b []byte) (typ uint16, win, n uint32) {
	t.Helper()
	if len(b) < 12 {
		t.Fatalf("short message: %d bytes", len(b))
	}
	return binary.LittleEndian.Uint16(b), binary.LittleEndian.Uint32(b[4:]), binary.LittleEndian.Uint32(b[8:])
}

func TestHelloAndDamage(t *testing.T) {
	p := &pipe{}
	c, err := Dial(p)
	if err != nil {
		t.Fatal(err)
	}
	b := p.out.Bytes()
	if typ, win, n := header(t, b); typ != Hello || win != 0 || n != 8 ||
		binary.LittleEndian.Uint32(b[12:]) != Magic || binary.LittleEndian.Uint32(b[16:]) != Version {
		t.Fatalf("bad HELLO % x", b)
	}
	p.out.Reset()

	// 4x2 frame, damage the 2x1 rectangle at (1,1).
	frame := make([]byte, 4*2*4)
	for i := range frame {
		frame[i] = byte(i)
	}
	if err := c.Damage(7, frame, 16, 1, 1, 2, 1); err != nil {
		t.Fatal(err)
	}
	b = p.out.Bytes()
	typ, win, n := header(t, b)
	if typ != Damage || win != 7 || n != 16+8 {
		t.Fatalf("header %d %d %d", typ, win, n)
	}
	if !bytes.Equal(b[28:], frame[20:28]) {
		t.Fatalf("pixels % x, want % x", b[28:], frame[20:28])
	}
}

func TestSizeLimits(t *testing.T) {
	c := &Conn{rw: &pipe{}}
	for _, s := range [][2]int{{0, 1}, {1, 0}, {MaxSide + 1, 1}, {-1, 5}} {
		if c.Create(1, s[0], s[1]) == nil {
			t.Errorf("Create %v accepted", s)
		}
	}
	if err := c.Create(1, MaxSide, MaxSide); err != nil {
		t.Error(err)
	}
}

func TestTitleCutOnRune(t *testing.T) {
	p := &pipe{}
	c := &Conn{rw: p}
	if err := c.SetTitle(1, strings.Repeat("é", MaxTitle)); err != nil {
		t.Fatal(err)
	}
	_, _, n := header(t, p.out.Bytes())
	if n > MaxTitle || !utf8.Valid(p.out.Bytes()[12:]) {
		t.Fatalf("title %d bytes, valid=%v", n, utf8.Valid(p.out.Bytes()[12:]))
	}
}

func msg(typ uint16, win uint32, payload ...uint32) []byte {
	b := make([]byte, 12+4*len(payload))
	binary.LittleEndian.PutUint16(b, typ)
	binary.LittleEndian.PutUint32(b[4:], win)
	binary.LittleEndian.PutUint32(b[8:], uint32(4*len(payload)))
	for i, v := range payload {
		binary.LittleEndian.PutUint32(b[12+4*i:], v)
	}
	return b
}

func TestNext(t *testing.T) {
	p := &pipe{}
	p.in.Write(msg(Key, 3, 30, 1))
	p.in.Write(msg(Close, 3))
	p.in.Write(msg(Motion, 3, uint32(0xffffffff), 5)) // x = -1
	c := &Conn{rw: p}
	for _, want := range []Event{{Key, 3, 30, 1}, {Close, 3, 0, 0}, {Motion, 3, -1, 5}} {
		ev, err := c.Next()
		if err != nil || ev != want {
			t.Fatalf("got %+v %v, want %+v", ev, err, want)
		}
	}
}

func TestNextRejects(t *testing.T) {
	for name, b := range map[string][]byte{
		"unknown type":   msg(0x99, 1),
		"guest type":     msg(Create, 1, 1, 1),
		"wrong length":   msg(Key, 1, 30),
		"nonzero flags":  func() []byte { m := msg(Close, 1); m[2] = 1; return m }(),
		"oversized body": msg(Focus, 1, 1, 2, 3),
	} {
		p := &pipe{}
		p.in.Write(b)
		if _, err := (&Conn{rw: p}).Next(); err != ErrProtocol {
			t.Errorf("%s: err %v, want ErrProtocol", name, err)
		}
	}
}
