// llmctl: control the host's model server from a Windows or macOS guest
// (llm/README.md). One request line to llmctl-host over vsock (host CID 2, port
// 21000), one JSON line back. The host answers only CIDs allowed with `llm allow`.
//
//	llmctl status | models | restart | use SHA256
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"vmgui-agent/platform"
)

const (
	hostCID = 2
	port    = 21000
)

func main() {
	a := os.Args[1:]
	ok := len(a) == 1 && (a[0] == "status" || a[0] == "models" || a[0] == "restart") ||
		len(a) == 2 && a[0] == "use"
	if !ok {
		fmt.Fprintln(os.Stderr, "usage: llmctl status | models | restart | use SHA256")
		os.Exit(2)
	}
	// LLMCTL_HOST_CID=1 (vsock loopback) and LLMCTL_PORT are for the e2e only.
	cid, p := uint64(hostCID), uint64(port)
	if v := os.Getenv("LLMCTL_HOST_CID"); v != "" {
		cid, _ = strconv.ParseUint(v, 10, 32)
	}
	if v := os.Getenv("LLMCTL_PORT"); v != "" {
		p, _ = strconv.ParseUint(v, 10, 32)
	}
	c, err := platform.DialHost(uint32(cid), uint32(p))
	if err != nil {
		fmt.Fprintln(os.Stderr, "llmctl:", err)
		os.Exit(1)
	}
	defer c.Close()
	// `use` hashes the model on the host first; the host gives up after 120 s.
	timer := time.AfterFunc(130*time.Second, func() { c.Close() })
	defer timer.Stop()
	if _, err := fmt.Fprintf(c, "%s\n", strings.Join(a, " ")); err != nil {
		fmt.Fprintln(os.Stderr, "llmctl:", err)
		os.Exit(1)
	}
	line, err := bufio.NewReader(c).ReadBytes('\n')
	if len(line) == 0 {
		fmt.Fprintln(os.Stderr, "llmctl: no answer (is this guest's CID allowed on the host? llm allow CID)", err)
		os.Exit(1)
	}
	var reply map[string]any
	if err := json.Unmarshal(line, &reply); err != nil {
		fmt.Fprintln(os.Stderr, "llmctl: bad answer:", err)
		os.Exit(1)
	}
	var out bytes.Buffer
	json.Indent(&out, line, "", "  ")
	fmt.Println(out.String())
	if reply["ok"] != true {
		os.Exit(1)
	}
}
