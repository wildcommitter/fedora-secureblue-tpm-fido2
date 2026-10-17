package pamauth

import (
	"bufio"
	"bytes"
	"io"
	"testing"
)

// fakeHelper plays the helper side of the protocol: it sends `script` and
// reads one answer after every prompt frame.
func fakeHelper(t *testing.T, toParent io.WriteCloser, fromParent io.Reader, script []struct {
	typ     byte
	payload string
}) <-chan []string {
	got := make(chan []string, 1)
	go func() {
		defer toParent.Close()
		in := bufio.NewReader(fromParent)
		var answers []string
		for _, f := range script {
			if err := writeFrame(toParent, f.typ, []byte(f.payload)); err != nil {
				t.Errorf("helper write: %v", err)
				break
			}
			if f.typ == framePromptEchoOff || f.typ == framePromptEchoOn {
				a, err := readFramedBytes(in)
				if err != nil {
					t.Errorf("helper read answer: %v", err)
					break
				}
				answers = append(answers, string(a))
			}
		}
		got <- answers
	}()
	return got
}

func TestConverseAsksEachPromptSeparately(t *testing.T) {
	helperOut, parentIn := io.Pipe()
	parentOut, helperIn := io.Pipe()
	script := []struct {
		typ     byte
		payload string
	}{
		{framePromptEchoOff, "Please enter the PIN: "},
		{frameStatusInfo, "Please touch the device."},
		{framePromptEchoOff, "Password: "},
		{frameResultOK, ""},
	}
	got := fakeHelper(t, parentIn, parentOut, script)

	var statuses, prompts []string
	var handed [][]byte
	answers := map[string]string{"Please enter the PIN: ": "123456", "Password: ": "hunter2"}
	res, err := converse(helperOut, helperIn, Handler{
		Status: func(m string, isErr bool) { statuses = append(statuses, m) },
		Prompt: func(p string, echo bool) ([]byte, error) {
			if echo {
				t.Errorf("prompt %q should not echo", p)
			}
			prompts = append(prompts, p)
			b := []byte(answers[p])
			handed = append(handed, b)
			return b, nil
		},
	})
	if err != nil || res == nil || !res.Success {
		t.Fatalf("converse = %+v, %v; want success", res, err)
	}
	if a := <-got; len(a) != 2 || a[0] != "123456" || a[1] != "hunter2" {
		t.Fatalf("helper got answers %q, want [123456 hunter2]", a)
	}
	if len(prompts) != 2 || len(statuses) != 1 || statuses[0] != "Please touch the device." {
		t.Fatalf("prompts %q statuses %q", prompts, statuses)
	}
	for _, b := range handed {
		if !bytes.Equal(b, make([]byte, len(b))) {
			t.Errorf("answer %q was not zeroed after sending", b)
		}
	}
}

func TestConverseFailure(t *testing.T) {
	helperOut, parentIn := io.Pipe()
	parentOut, helperIn := io.Pipe()
	script := []struct {
		typ     byte
		payload string
	}{
		{frameStatusError, "Wrong PIN"},
		{frameResultFail, "Authentication failure"},
	}
	fakeHelper(t, parentIn, parentOut, script)
	var errs []string
	res, err := converse(helperOut, helperIn, Handler{
		Status: func(m string, isErr bool) {
			if isErr {
				errs = append(errs, m)
			}
		},
	})
	if err != nil || res == nil || res.Success || res.Message != "Authentication failure" {
		t.Fatalf("converse = %+v, %v; want failure", res, err)
	}
	if len(errs) != 1 || errs[0] != "Wrong PIN" {
		t.Fatalf("error statuses %q", errs)
	}
}
