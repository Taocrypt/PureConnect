package main

// Lightweight mode: the UI can exit while the VPN keeps running.
//
// The UI sends {"cmd":"detach","token":T,"restore":{...}}. From then on the
// core no longer exits when its protocol channel closes; it listens on
// 127.0.0.1:<random port> and a later UI (whose app data dir holds the port
// and token, readable by the user only) re-attaches there:
//
//	UI -> core: {"token":T,"mode":"attach"|"ping"}\n
//	core -> UI: attach: hello, state, session, the logs no UI saw, flows,
//	            traffic, then live events; the UI's commands are read from
//	            the same connection (stop, probe, challenge_response, detach).
//	            ping: one {"type":"pong","state":...} line, then close.
//
// A wrong token or a handshake that doesn't arrive within a few seconds just
// closes the connection. When the core ends while detached (stop, kicked
// offline, any fatal error) it first runs the restore plan (system proxy)
// and removes the attach file, so nothing is left behind without a UI.

import (
	"bufio"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
)

const (
	backlogMax       = 500
	handshakeTimeout = 5 * time.Second
	minTokenLen      = 32
)

// RestorePlan is what the core undoes on exit when no UI is around.
type RestorePlan struct {
	// Commands restoring the system proxy (macOS networksetup, Linux
	// gsettings / kwriteconfig), run in order.
	Exec [][]string `json:"exec,omitempty"`
	// Windows: per-user WinINet settings to write back.
	WinProxy *WinProxy `json:"win_proxy,omitempty"`
	// The UI's proxy backup, deleted once the proxy was restored (the next
	// UI launch restores from it when that failed).
	ProxyBackup string `json:"proxy_backup,omitempty"`
	// The attach file (port + token), removed on exit.
	AttachFile string `json:"attach_file,omitempty"`
	// Written with the error when the core ends with one while no UI is
	// attached, so the next launch can say what happened.
	ExitNote string `json:"exit_note,omitempty"`
}

type WinProxy struct {
	Enable        int     `json:"enable"`
	Server        string  `json:"server"`
	Bypass        string  `json:"bypass"`
	AutoConfigURL *string `json:"autoConfigUrl"`
}

// Binaries a restore plan may run, and the file names it may touch.
var (
	allowedRestoreExec = map[string]bool{
		"networksetup": true, "gsettings": true, "dbus-send": true,
		"kwriteconfig": true, "kwriteconfig5": true, "kwriteconfig6": true,
	}
	allowedPlanFiles = map[string]string{
		"proxy_backup": "system_proxy_backup.json",
		"attach_file":  "core_attach.json",
		"exit_note":    "core_exit.json",
	}
)

func (p *RestorePlan) validate() error {
	for _, argv := range p.Exec {
		if len(argv) == 0 || !allowedRestoreExec[filepath.Base(argv[0])] {
			return errors.New("restore: command not allowed")
		}
	}
	check := func(kind, path string) error {
		if path == "" {
			return nil
		}
		if !filepath.IsAbs(path) || filepath.Base(path) != allowedPlanFiles[kind] {
			return errors.New("restore: bad " + kind + " path")
		}
		return nil
	}
	if err := check("proxy_backup", p.ProxyBackup); err != nil {
		return err
	}
	if err := check("attach_file", p.AttachFile); err != nil {
		return err
	}
	return check("exit_note", p.ExitNote)
}

// run restores the system proxy; true when that worked (or there was none).
func (p *RestorePlan) runProxy() bool {
	ok := true
	if p.WinProxy != nil {
		if err := restoreWinProxy(p.WinProxy); err != nil {
			ok = false
		}
	}
	for _, argv := range p.Exec {
		cmd := exec.Command(argv[0], argv[1:]...)
		done := make(chan error, 1)
		if err := cmd.Start(); err != nil {
			ok = false
			continue
		}
		go func() { done <- cmd.Wait() }()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			_ = cmd.Process.Kill()
			ok = false
		}
	}
	return ok
}

type attachClient struct {
	conn net.Conn
}

// attachHub keeps lightweight-mode state: re-attached UIs, the latest
// events of each kind for replay, and the logs nobody has seen yet.
type attachHub struct {
	em *emitter

	mu       sync.Mutex
	detached bool
	token    string
	ln       net.Listener
	clients  map[*attachClient]struct{}
	sticky   map[string][]byte
	backlog  [][]byte
	plan     *RestorePlan
	onClient func(c net.Conn) // reads the client's commands
}

func newAttachHub(em *emitter) *attachHub {
	return &attachHub{em: em, clients: map[*attachClient]struct{}{}, sticky: map[string][]byte{}}
}

var stickyTypes = map[string]bool{
	"hello": true, "state": true, "session": true, "flows": true, "traffic": true, "proxy_status": true,
}

// replayOrder is the order a re-attached UI receives the sticky events in.
var replayOrder = []string{"hello", "state", "session", "proxy_status"}

// publish is called by the emitter (under its lock) for every event.
func (h *attachHub) publish(typ string, line []byte, delivered bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if stickyTypes[typ] {
		h.sticky[typ] = line
	}
	for c := range h.clients {
		_ = c.conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
		if _, err := c.conn.Write(line); err != nil {
			delete(h.clients, c)
			_ = c.conn.Close()
		} else {
			delivered = true
		}
	}
	if !delivered && h.detached && typ == "log" {
		h.backlog = append(h.backlog, line)
		if len(h.backlog) > backlogMax {
			h.backlog = h.backlog[len(h.backlog)-backlogMax:]
		}
	}
}

func (h *attachHub) isDetached() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.detached
}

func (h *attachHub) clientCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.clients)
}

// detach turns lightweight mode on (idempotent) and returns the port.
// Only the starting UI (primary) may set the token and the restore plan.
func (h *attachHub) detach(token string, plan *RestorePlan, primary bool) (int, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if primary {
		if len(token) < minTokenLen {
			return 0, errors.New("detach: token too short")
		}
		if plan != nil {
			if err := plan.validate(); err != nil {
				return 0, err
			}
		}
	}
	if h.ln == nil {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			return 0, err
		}
		h.ln = ln
		go h.acceptLoop(ln)
	}
	if primary {
		h.token = token
		if plan != nil {
			h.plan = plan
		}
	}
	if !h.detached {
		h.detached = true
		ignoreHangup()
	}
	return h.ln.Addr().(*net.TCPAddr).Port, nil
}

func (h *attachHub) acceptLoop(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go h.handshake(c)
	}
}

type attachHello struct {
	Token string `json:"token"`
	Mode  string `json:"mode"` // attach | ping
}

func (h *attachHub) checkToken(t string) bool {
	h.mu.Lock()
	want := h.token
	h.mu.Unlock()
	return want != "" && subtle.ConstantTimeCompare([]byte(t), []byte(want)) == 1
}

func (h *attachHub) handshake(c net.Conn) {
	_ = c.SetReadDeadline(time.Now().Add(handshakeTimeout))
	r := bufio.NewReaderSize(c, 4096)
	line, err := r.ReadSlice('\n')
	var hello attachHello
	if err != nil || json.Unmarshal(line, &hello) != nil || !h.checkToken(hello.Token) {
		_ = c.Close()
		return
	}
	_ = c.SetReadDeadline(time.Time{})
	if hello.Mode == "ping" {
		h.mu.Lock()
		state := ""
		if s, ok := h.sticky["state"]; ok {
			var ev Event
			if json.Unmarshal(s, &ev) == nil {
				state = ev.State
			}
		}
		h.mu.Unlock()
		_ = c.SetWriteDeadline(time.Now().Add(2 * time.Second))
		_, _ = c.Write(encodeEvent(Event{Type: "pong", State: state, PID: os.Getpid(), Time: time.Now().UnixMilli()}))
		_ = c.Close()
		return
	}
	client := &attachClient{conn: c}
	// Under the emitter lock, so no live event slips in before the replay.
	h.em.mu.Lock()
	h.mu.Lock()
	_ = c.SetWriteDeadline(time.Now().Add(5 * time.Second))
	var werr error
	write := func(b []byte) {
		if werr == nil && b != nil {
			_, werr = c.Write(b)
		}
	}
	for _, t := range replayOrder {
		write(h.sticky[t])
	}
	for _, b := range h.backlog {
		write(b)
	}
	write(h.sticky["flows"])
	write(h.sticky["traffic"])
	if werr == nil {
		h.backlog = nil
		h.clients[client] = struct{}{}
	}
	onClient := h.onClient
	h.mu.Unlock()
	h.em.mu.Unlock()
	if werr != nil {
		_ = c.Close()
		return
	}
	if onClient != nil {
		onClient(&bufferedConn{Conn: c, r: r})
	}
	h.mu.Lock()
	delete(h.clients, client)
	h.mu.Unlock()
	_ = c.Close()
}

// bufferedConn reads through the handshake's reader (it may hold the
// client's first command already).
type bufferedConn struct {
	net.Conn
	r *bufio.Reader
}

func (b *bufferedConn) Read(p []byte) (int, error) { return b.r.Read(p) }

// finish runs on core exit: restores the proxy, notes an error nobody saw,
// removes the attach file and drops the re-attached UIs.
func (h *attachHub) finish(code int, lastErr string, uiPresent bool) {
	h.mu.Lock()
	plan := h.plan
	detached := h.detached
	ln := h.ln
	h.mu.Unlock()
	if plan != nil {
		if plan.runProxy() && plan.ProxyBackup != "" {
			_ = os.Remove(plan.ProxyBackup)
		}
		if plan.AttachFile != "" {
			_ = os.Remove(plan.AttachFile)
		}
		if detached && code != 0 && !uiPresent && plan.ExitNote != "" {
			b, _ := json.Marshal(map[string]any{"error": lastErr, "code": code, "time": time.Now().UnixMilli()})
			_ = os.WriteFile(plan.ExitNote, b, 0o644)
		}
	}
	if ln != nil {
		_ = ln.Close()
	}
}

// closeClients flushes nothing more and hangs up on re-attached UIs (their
// connection closing is how they learn the core exited).
func (h *attachHub) closeClients() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for c := range h.clients {
		_ = c.conn.Close()
		delete(h.clients, c)
	}
}
