package main

import (
	"net"
	"testing"
	"time"

	"hardened-unlock/internal/duress"
)

func TestRequestMatchesLocker(t *testing.T) {
	if request != duress.Request {
		t.Fatalf("request byte %q differs from duress.Request %q", request, duress.Request)
	}
}

func TestHandle(t *testing.T) {
	for _, tc := range []struct {
		name string
		send []byte
		want bool
	}{
		{"request", []byte{request}, true},
		{"wrong byte", []byte("x"), false},
		{"two bytes", []byte{request, request}, false},
		{"nothing", nil, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv, cli := net.Pipe()
			go func() {
				if len(tc.send) > 0 {
					_, _ = cli.Write(tc.send)
				}
				if tc.send == nil {
					cli.Close()
				}
			}()
			_ = srv.SetDeadline(time.Now().Add(3 * time.Second))
			if got := handle(srv); got != tc.want {
				t.Fatalf("handle(%q) = %v, want %v", tc.send, got, tc.want)
			}
			srv.Close()
			cli.Close()
		})
	}
}

func TestServeResetsOnRequest(t *testing.T) {
	l, err := net.Listen("unix", t.TempDir()+"/s")
	if err != nil {
		t.Fatal(err)
	}
	resets := make(chan struct{}, 4)
	go serve(l, func() error { resets <- struct{}{}; return nil })

	send := func(b []byte) {
		c, err := net.Dial("unix", l.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		_, _ = c.Write(b)
		time.Sleep(100 * time.Millisecond)
		c.Close()
	}
	send([]byte("junk"))
	send([]byte{request})
	select {
	case <-resets:
	case <-time.After(3 * time.Second):
		t.Fatal("no reset after a valid request")
	}
	select {
	case <-resets:
		t.Fatal("reset after a malformed request")
	case <-time.After(300 * time.Millisecond):
	}
	l.Close()
}
