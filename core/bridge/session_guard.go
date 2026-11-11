package main

// Ending a session whose tunnel died.
//
// Upstream's L3 connection retries a broken stream a few times and then
// returns the error; its stacks then panic (desktop gVisor/TUN) or the
// Android pump stops with a generic "tunnel closed". Both lose the reason.
// The guard below catches that final error, reports it as the session's
// error and shuts the core down cleanly (the stack goroutines are parked
// until the process exits, so nothing panics).
//
// Kicked offline: when the same EasyConnect account signs in elsewhere, the
// server drops our receive stream (EOF) and then refuses the re-handshake
// ("unexpected recv handshake reply"). That gets its own error text, which
// the UI shows as "signed in on another device" and never auto-reconnects
// (reconnecting would just kick the other device and loop).

import (
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"sync"

	"github.com/mythologyli/zju-connect/client"
	easyconnectclient "github.com/mythologyli/zju-connect/client/easyconnect"
	"github.com/mythologyli/zju-connect/internal/hook_func"
)

// errKickedText starts the error reported when the session was taken over;
// lib/core/errors.dart matches it ("kicked").
const errKickedText = "kicked offline: the account signed in on another device"

var (
	fatalMu   sync.Mutex
	fatalOnce sync.Once
	// fatalHook ends the session with err (set by main).
	fatalHook func(err error)
	// park blocks the caller forever once the session is ending.
	park = func() { select {} }
)

func setFatalHook(f func(error)) {
	fatalMu.Lock()
	fatalHook = f
	fatalMu.Unlock()
}

// isKicked: the receive stream was refused after it had been working.
func isKicked(err error) bool {
	return errors.Is(err, easyconnectclient.ErrRecvHandshakeRejected)
}

// tunnelError turns the L3 connection's final error into the session error.
func tunnelError(err error) error {
	if isKicked(err) {
		return fmt.Errorf("%s (%w)", errKickedText, err)
	}
	return fmt.Errorf("tunnel closed: %w", err)
}

// tunnelFailed reports a dead tunnel once. It returns false while the core is
// already stopping (errors then are expected) or when no hook is set.
func tunnelFailed(err error) bool {
	if err == nil || hook_func.IsTerminal() {
		return false
	}
	fatalMu.Lock()
	h := fatalHook
	fatalMu.Unlock()
	if h == nil {
		return false
	}
	e := tunnelError(err)
	fatalOnce.Do(func() {
		log.Printf("Tunnel failed: %v", e)
		h(e)
	})
	return true
}

type guardL3Conn struct{ io.ReadWriteCloser }

func newGuardL3Conn(c io.ReadWriteCloser) io.ReadWriteCloser { return &guardL3Conn{c} }

func (g *guardL3Conn) Read(p []byte) (int, error) {
	n, err := g.ReadWriteCloser.Read(p)
	if err != nil && tunnelFailed(err) {
		park()
	}
	return n, err
}

func (g *guardL3Conn) Write(p []byte) (int, error) {
	n, err := g.ReadWriteCloser.Write(p)
	if err != nil && tunnelFailed(err) {
		park()
	}
	return n, err
}

// guardClient hands the stacks guarded L3 connections.
type guardClient struct{ client.Client }

func newGuardClient(c client.Client) client.Client { return &guardClient{c} }

func (c *guardClient) SetIPUpdateHandler(h func(net.IP) error) {
	client.RegisterIPUpdateHandler(c.Client, h)
}

func (c *guardClient) NewL3Conn() (io.ReadWriteCloser, error) {
	l3, err := c.Client.NewL3Conn()
	if err != nil {
		return nil, err
	}
	return newGuardL3Conn(l3), nil
}
