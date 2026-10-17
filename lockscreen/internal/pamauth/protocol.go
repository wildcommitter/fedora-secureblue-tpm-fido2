// Package pamauth authenticates the current user against a PAM service in a
// short-lived helper subprocess, streaming PAM_TEXT_INFO / PAM_ERROR_MSG
// conversation messages back to the caller as they happen (e.g. pam_u2f's
// "Please touch the device" cue), instead of discarding them.
package pamauth

import (
	"encoding/binary"
	"errors"
	"io"
)

// Frame types written by the helper subprocess on its stdout pipe. After a
// prompt frame the helper blocks until the parent writes the answer on the
// helper's stdin with writeFramedBytes.
const (
	frameStatusInfo    byte = 1 // TextInfo conversation message
	frameStatusError   byte = 2 // ErrorMsg conversation message
	frameResultOK      byte = 3 // authentication succeeded (payload empty)
	frameResultFail    byte = 4 // authentication failed (payload = reason)
	framePromptEchoOff byte = 5 // secret prompt, e.g. "Password: " (payload = prompt text)
	framePromptEchoOn  byte = 6 // visible prompt (payload = prompt text)
)

const maxFramePayload = 8192

// writeFrame writes a length-prefixed frame: 1 byte type + 4 byte
// big-endian length + payload.
func writeFrame(w io.Writer, typ byte, payload []byte) error {
	header := make([]byte, 5)
	header[0] = typ
	binary.BigEndian.PutUint32(header[1:], uint32(len(payload)))
	if _, err := w.Write(header); err != nil {
		return err
	}
	if len(payload) == 0 {
		return nil
	}
	_, err := w.Write(payload)
	return err
}

func readFrame(r io.Reader) (typ byte, payload []byte, err error) {
	header := make([]byte, 5)
	if _, err := io.ReadFull(r, header); err != nil {
		return 0, nil, err
	}
	typ = header[0]
	length := binary.BigEndian.Uint32(header[1:])
	if length > maxFramePayload {
		return 0, nil, errors.New("pamauth: frame too large")
	}
	if length == 0 {
		return typ, nil, nil
	}
	payload = make([]byte, length)
	if _, err := io.ReadFull(r, payload); err != nil {
		return 0, nil, err
	}
	return typ, payload, nil
}

// writeFramedBytes writes a single 4-byte big-endian length prefix followed
// by the raw bytes of b. Used by the parent to answer each prompt frame.
func writeFramedBytes(w io.Writer, b []byte) error {
	var lenBuf [4]byte
	binary.BigEndian.PutUint32(lenBuf[:], uint32(len(b)))
	if _, err := w.Write(lenBuf[:]); err != nil {
		return err
	}
	if len(b) == 0 {
		return nil
	}
	_, err := w.Write(b)
	return err
}

// readFramedBytes is the counterpart to writeFramedBytes. The caller owns
// the returned slice and is responsible for zeroing it once done (see
// zeroBytes).
func readFramedBytes(r io.Reader) ([]byte, error) {
	var lenBuf [4]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		return nil, err
	}
	length := binary.BigEndian.Uint32(lenBuf[:])
	if length > maxFramePayload {
		return nil, errors.New("pamauth: answer too large")
	}
	if length == 0 {
		return nil, nil
	}
	buf := make([]byte, length)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, err
	}
	return buf, nil
}

func zeroBytes(b []byte) {
	for i := range b {
		b[i] = 0
	}
}
