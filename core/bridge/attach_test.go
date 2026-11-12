package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

const testToken = "0123456789abcdef0123456789abcdef"

type syncBuf struct {
	mu  sync.Mutex
	buf bytes.Buffer
	err error
}

func (b *syncBuf) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.err != nil {
		return 0, b.err
	}
	return b.buf.Write(p)
}

func dialHub(t *testing.T, port int, hello string) (net.Conn, *bufio.Reader) {
	t.Helper()
	c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	_ = c.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := c.Write([]byte(hello + "\n")); err != nil {
		t.Fatal(err)
	}
	return c, bufio.NewReader(c)
}

func readEvent(t *testing.T, r *bufio.Reader) Event {
	t.Helper()
	line, err := r.ReadBytes('\n')
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var ev Event
	if err := json.Unmarshal(line, &ev); err != nil {
		t.Fatalf("decode %q: %v", line, err)
	}
	return ev
}

func TestDetachNeedsToken(t *testing.T) {
	em := newEmitter(&syncBuf{})
	if _, err := em.hub.detach("short", nil, true); err == nil {
		t.Fatal("short token accepted")
	}
	if em.hub.isDetached() {
		t.Fatal("detached without a token")
	}
}

func TestAttachWrongTokenIsRejected(t *testing.T) {
	em := newEmitter(&syncBuf{})
	port, err := em.hub.detach(testToken, nil, true)
	if err != nil {
		t.Fatal(err)
	}
	c, r := dialHub(t, port, `{"token":"0123456789abcdef0123456789abcdee","mode":"attach"}`)
	defer c.Close()
	if _, err := r.ReadBytes('\n'); err == nil {
		t.Fatal("wrong token got data")
	}
	c2, r2 := dialHub(t, port, "not json")
	defer c2.Close()
	if _, err := r2.ReadBytes('\n'); err == nil {
		t.Fatal("garbage handshake got data")
	}
}

func TestPingReportsState(t *testing.T) {
	em := newEmitter(&syncBuf{})
	em.state("connected", nil)
	port, err := em.hub.detach(testToken, nil, true)
	if err != nil {
		t.Fatal(err)
	}
	c, r := dialHub(t, port, `{"token":"`+testToken+`","mode":"ping"}`)
	defer c.Close()
	ev := readEvent(t, r)
	if ev.Type != "pong" || ev.State != "connected" || ev.PID != os.Getpid() {
		t.Fatalf("pong = %+v", ev)
	}
}

func TestAttachReplaysAndForwardsCommands(t *testing.T) {
	primary := &syncBuf{}
	em := newEmitter(primary)
	em.emit(Event{Type: "hello", Version: "v"})
	em.state("connected", nil)
	em.emit(Event{Type: "session", Session: &SessionInfo{IP: "10.0.0.2"}})
	em.log("info", "before detach") // the UI saw this one
	port, err := em.hub.detach(testToken, nil, true)
	if err != nil {
		t.Fatal(err)
	}
	// The UI exits: its channel breaks, logs now go to the backlog.
	primary.mu.Lock()
	primary.err = fmt.Errorf("broken pipe")
	primary.mu.Unlock()
	em.log("info", "while detached 1")
	em.log("info", "while detached 2")
	em.emit(Event{Type: "flows", Flows: []FlowInfo{{Host: "a"}}})
	if em.hasPrimary() {
		t.Fatal("primary kept after write error")
	}

	got := make(chan Command, 1)
	em.hub.onClient = func(c net.Conn) {
		readCommands(c, em, func(cmd Command) { got <- cmd })
	}
	c, r := dialHub(t, port, `{"token":"`+testToken+`","mode":"attach"}`)
	defer c.Close()
	var types, logs []string
	for i := 0; i < 6; i++ {
		ev := readEvent(t, r)
		types = append(types, ev.Type)
		if ev.Type == "log" {
			logs = append(logs, ev.Message)
		}
	}
	if strings.Join(types, ",") != "hello,state,session,log,log,flows" {
		t.Fatalf("replay order %v", types)
	}
	if strings.Join(logs, "|") != "while detached 1|while detached 2" {
		t.Fatalf("backlog %v", logs)
	}
	// Live events reach the re-attached UI, and nothing is buffered twice.
	em.log("info", "live")
	if ev := readEvent(t, r); ev.Message != "live" {
		t.Fatalf("live = %+v", ev)
	}
	em.hub.mu.Lock()
	n := len(em.hub.backlog)
	em.hub.mu.Unlock()
	if n != 0 {
		t.Fatalf("backlog not cleared: %d", n)
	}
	if _, err := c.Write([]byte(`{"cmd":"stop"}` + "\n")); err != nil {
		t.Fatal(err)
	}
	select {
	case cmd := <-got:
		if cmd.Cmd != "stop" {
			t.Fatalf("cmd = %+v", cmd)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("command not forwarded")
	}
}

func TestBacklogIsBounded(t *testing.T) {
	em := newEmitter(nil)
	if _, err := em.hub.detach(testToken, nil, true); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < backlogMax+50; i++ {
		em.log("info", fmt.Sprint(i))
	}
	em.hub.mu.Lock()
	defer em.hub.mu.Unlock()
	if len(em.hub.backlog) != backlogMax {
		t.Fatalf("backlog = %d", len(em.hub.backlog))
	}
}

func TestReattachedUICannotChangeTokenOrPlan(t *testing.T) {
	em := newEmitter(nil)
	plan := &RestorePlan{AttachFile: filepath.Join(t.TempDir(), "core_attach.json")}
	if _, err := em.hub.detach(testToken, plan, true); err != nil {
		t.Fatal(err)
	}
	other := &RestorePlan{Exec: [][]string{{"gsettings", "set", "x", "y", "z"}}}
	if _, err := em.hub.detach("ffffffffffffffffffffffffffffffff", other, false); err != nil {
		t.Fatal(err)
	}
	if !em.hub.checkToken(testToken) || em.hub.plan != plan {
		t.Fatal("a re-attached UI changed the token or the plan")
	}
}

func TestRestorePlanValidation(t *testing.T) {
	dir := t.TempDir()
	ok := &RestorePlan{
		Exec:        [][]string{{"networksetup", "-setwebproxystate", "Wi-Fi", "off"}, {"/usr/bin/gsettings", "set", "a", "b", "c"}},
		ProxyBackup: filepath.Join(dir, "system_proxy_backup.json"),
		AttachFile:  filepath.Join(dir, "core_attach.json"),
		ExitNote:    filepath.Join(dir, "core_exit.json"),
	}
	if err := ok.validate(); err != nil {
		t.Fatal(err)
	}
	bad := []*RestorePlan{
		{Exec: [][]string{{"sh", "-c", "id"}}},
		{Exec: [][]string{{}}},
		{AttachFile: "core_attach.json"},
		{ProxyBackup: filepath.Join(dir, "passwd")},
		{ExitNote: filepath.Join(dir, "core_attach.json")},
	}
	for i, p := range bad {
		if p.validate() == nil {
			t.Errorf("bad plan %d accepted", i)
		}
	}
}

func TestFinishRemovesFilesAndWritesNote(t *testing.T) {
	dir := t.TempDir()
	attach := filepath.Join(dir, "core_attach.json")
	backup := filepath.Join(dir, "system_proxy_backup.json")
	note := filepath.Join(dir, "core_exit.json")
	for _, f := range []string{attach, backup} {
		if err := os.WriteFile(f, []byte("{}"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	em := newEmitter(nil)
	plan := &RestorePlan{ProxyBackup: backup, AttachFile: attach, ExitNote: note}
	if _, err := em.hub.detach(testToken, plan, true); err != nil {
		t.Fatal(err)
	}
	em.hub.finish(1, "kicked offline", false)
	for _, f := range []string{attach, backup} {
		if _, err := os.Stat(f); !os.IsNotExist(err) {
			t.Errorf("%s left behind", filepath.Base(f))
		}
	}
	b, err := os.ReadFile(note)
	if err != nil || !strings.Contains(string(b), "kicked offline") {
		t.Fatalf("exit note %q %v", b, err)
	}
}
