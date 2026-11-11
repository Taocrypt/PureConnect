package main

import (
	"errors"
	"fmt"
	"io"
	"strings"
	"testing"

	easyconnectclient "github.com/mythologyli/zju-connect/client/easyconnect"
)

type failingRWC struct{ err error }

func (f failingRWC) Read([]byte) (int, error)  { return 0, f.err }
func (f failingRWC) Write([]byte) (int, error) { return 0, f.err }
func (f failingRWC) Close() error              { return nil }

func TestTunnelErrorClassification(t *testing.T) {
	kicked := fmt.Errorf("%w (0x00)", easyconnectclient.ErrRecvHandshakeRejected)
	if e := tunnelError(kicked); !strings.HasPrefix(e.Error(), errKickedText) || !isKicked(e) {
		t.Fatalf("kicked: %v", e)
	}
	if e := tunnelError(io.EOF); isKicked(e) || !strings.HasPrefix(e.Error(), "tunnel closed: ") {
		t.Fatalf("eof: %v", e)
	}
}

// A dead tunnel is reported once through the hook and the caller is parked
// instead of getting an error the upstream stacks would panic on.
func TestGuardReportsOnceAndParks(t *testing.T) {
	var got []error
	setFatalHook(func(err error) { got = append(got, err) })
	defer setFatalHook(nil)
	parked := 0
	park = func() { parked++ }
	defer func() { park = func() { select {} } }()

	kicked := fmt.Errorf("%w (0x00)", easyconnectclient.ErrRecvHandshakeRejected)
	g := newGuardL3Conn(failingRWC{kicked})
	_, _ = g.Read(make([]byte, 4))
	_, _ = g.Write([]byte{1})
	if len(got) != 1 || !strings.HasPrefix(got[0].Error(), errKickedText) || !errors.Is(got[0], easyconnectclient.ErrRecvHandshakeRejected) {
		t.Fatalf("hook calls: %v", got)
	}
	if parked != 2 {
		t.Fatalf("parked %d", parked)
	}
}
