// vmgui-agent: show this guest's windows on the host's scroll session, each as a
// host window framed in the VM's color (vmgui, Qubes-style). For guests without
// Wayland: Windows 11 and macOS. Speaks vmgui/PROTOCOL.md over vsock to host
// CID 2, port 20000 + this guest's CID; the host accepts only that CID.
//
//	vmgui-agent [-cid N] [-fps 15]
//
// -host-cid 1 (vsock loopback, with -cid 1) is for the e2e only.
package main

import (
	"bytes"
	"flag"
	"fmt"
	"io"
	"log"
	"time"

	"vmgui-agent/platform"
	"vmgui-agent/wire"
)

const (
	portBase = 20000
	tile     = 64
)

type win struct {
	w, h  int
	title string
	prev  []byte
	cur   []byte
}

func main() {
	cid := flag.Uint("cid", 0, "this guest's vsock CID (default: ask the vsock driver)")
	fps := flag.Int("fps", 15, "capture rate per second")
	hostCID := flag.Uint("host-cid", 2, "host CID (1 = vsock loopback, e2e only)")
	flag.Parse()
	log.SetFlags(0)
	log.SetPrefix("vmgui-agent: ")

	plat, err := platform.New()
	if err != nil {
		log.Fatal(err)
	}
	if *cid == 0 {
		c, err := platform.LocalCID()
		if err != nil {
			log.Fatalf("no CID (%v): pass -cid, the number from `vmgui list` on the host", err)
		}
		*cid = uint(c)
	}
	if (*hostCID != 2 && *hostCID != 1) || (*cid < 3 && !(*hostCID == 1 && *cid == 1)) || *fps < 1 || *fps > 60 {
		log.Fatalf("bad -cid %d or -fps %d", *cid, *fps)
	}
	backoff := time.Second
	for {
		started := time.Now()
		err := session(plat, uint32(*hostCID), uint32(portBase+*cid), time.Second/time.Duration(*fps))
		if time.Since(started) > 30*time.Second {
			backoff = time.Second
		}
		log.Printf("%v; reconnecting in %v", err, backoff)
		time.Sleep(backoff)
		backoff = min(backoff*2, 30*time.Second)
	}
}

// session runs one connection until it fails; the host drops all our windows
// with it, so the next session starts from nothing.
func session(plat platform.Platform, hostCID, port uint32, interval time.Duration) error {
	rw, err := platform.DialHost(hostCID, port)
	if err != nil {
		return fmt.Errorf("vsock %d:%d: %w", hostCID, port, err)
	}
	defer rw.Close()
	c, err := wire.Dial(rw)
	if err != nil {
		return err
	}
	errc := make(chan error, 1)
	go func() { errc <- events(c, plat) }()

	wins := map[uint32]*win{}
	tick := time.NewTicker(interval)
	defer tick.Stop()
	for {
		select {
		case err := <-errc:
			return fmt.Errorf("host: %w", err)
		case <-tick.C:
		}
		if err := frame(c, plat, wins); err != nil {
			return err
		}
	}
}

func frame(c *wire.Conn, plat platform.Platform, wins map[uint32]*win) error {
	list, err := plat.Windows()
	if err != nil {
		return err
	}
	if len(list) > wire.MaxWindows {
		list = list[:wire.MaxWindows]
	}
	seen := map[uint32]bool{}
	for _, lw := range list {
		lw.W, lw.H = min(max(lw.W, 1), wire.MaxSide), min(max(lw.H, 1), wire.MaxSide)
		seen[lw.ID] = true
		st := wins[lw.ID]
		switch {
		case st == nil:
			if err := c.Create(lw.ID, lw.W, lw.H); err != nil {
				return err
			}
			st = &win{}
			wins[lw.ID] = st
		case st.w != lw.W || st.h != lw.H:
			if err := c.Resize(lw.ID, lw.W, lw.H); err != nil {
				return err
			}
		}
		if st.w != lw.W || st.h != lw.H {
			st.w, st.h = lw.W, lw.H
			st.prev = nil // everything is new after a resize
			st.cur = make([]byte, lw.W*lw.H*4)
		}
		if st.title != lw.Title {
			if err := c.SetTitle(lw.ID, lw.Title); err != nil {
				return err
			}
			st.title = lw.Title
		}
		if err := plat.Capture(lw.ID, st.w, st.h, st.cur); err != nil {
			continue // gone between listing and capture; the next frame drops it
		}
		if err := sendDamage(c, lw.ID, st); err != nil {
			return err
		}
	}
	for id := range wins {
		if !seen[id] {
			if err := c.Destroy(id); err != nil {
				return err
			}
			delete(wins, id)
		}
	}
	return nil
}

// sendDamage compares cur with prev in tiles and sends each run of changed
// tiles in a tile row as one rectangle.
func sendDamage(c *wire.Conn, id uint32, st *win) error {
	stride, sent := st.w*4, false
	for ty := 0; ty < st.h; ty += tile {
		th := min(tile, st.h-ty)
		run := -1
		flush := func(end int) error {
			if run < 0 {
				return nil
			}
			x, w := run, end-run
			run = -1
			sent = true
			return c.Damage(id, st.cur, stride, x, ty, w, th)
		}
		for tx := 0; tx < st.w; tx += tile {
			tw := min(tile, st.w-tx)
			if changed(st, tx, ty, tw, th) {
				if run < 0 {
					run = tx
				}
			} else if err := flush(tx); err != nil {
				return err
			}
		}
		if err := flush(st.w); err != nil {
			return err
		}
	}
	if st.prev == nil {
		st.prev = make([]byte, len(st.cur))
	}
	copy(st.prev, st.cur)
	if sent {
		return c.Commit(id)
	}
	return nil
}

func changed(st *win, x, y, w, h int) bool {
	if st.prev == nil {
		return true
	}
	stride := st.w * 4
	for r := y; r < y+h; r++ {
		o := r*stride + x*4
		if !bytes.Equal(st.cur[o:o+w*4], st.prev[o:o+w*4]) {
			return true
		}
	}
	return false
}

func events(c *wire.Conn, plat platform.Platform) error {
	for {
		ev, err := c.Next()
		if err != nil {
			if err == io.EOF {
				return fmt.Errorf("closed the connection")
			}
			return err
		}
		switch ev.Type {
		case wire.Configure:
			if ev.A > 0 && ev.B > 0 {
				plat.Resize(ev.Window, int(ev.A), int(ev.B))
			}
		case wire.Close:
			plat.Close(ev.Window)
		case wire.Focus:
			if ev.A == 1 {
				plat.Focus(ev.Window)
			}
		case wire.Motion:
			plat.Motion(ev.Window, int(ev.A), int(ev.B))
		case wire.Button:
			plat.Button(ev.Window, uint32(ev.A), ev.B != 0)
		case wire.Axis:
			plat.Axis(ev.Window, uint32(ev.A), ev.B)
		case wire.Key:
			plat.Key(ev.Window, uint32(ev.A), ev.B != 0)
		}
	}
}
