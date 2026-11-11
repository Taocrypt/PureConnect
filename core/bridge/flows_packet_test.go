package main

import (
	"bytes"
	"io"
	"testing"
)

func testTracker() *flowTracker {
	return &flowTracker{names: map[string]string{}, flows: map[flowKey]*flowEntry{}, byDst: map[string]flowKey{}, stop: make(chan struct{})}
}

// mkIPv4 builds a minimal IPv4 packet header + 4 bytes of ports.
func mkIPv4(proto byte, src, dst [4]byte, sp, dp uint16, extra int) []byte {
	p := make([]byte, 24+extra)
	p[0] = 0x45
	p[9] = proto
	copy(p[12:16], src[:])
	copy(p[16:20], dst[:])
	p[20], p[21] = byte(sp>>8), byte(sp)
	p[22], p[23] = byte(dp>>8), byte(dp)
	return p
}

func TestOutboundConn(t *testing.T) {
	pkt := mkIPv4(6, [4]byte{10, 1, 2, 3}, [4]byte{10, 9, 8, 7}, 50000, 443, 0)
	dst, id, ok := outboundConn(pkt)
	if !ok || dst != "10.9.8.7" || id != "tcp:10.1.2.3:50000>10.9.8.7:443" {
		t.Fatalf("got %q %q %v", dst, id, ok)
	}
	if _, _, ok := outboundConn([]byte{0x60, 0, 0}); ok {
		t.Fatal("IPv6/short packet accepted")
	}
	if _, id, ok := outboundConn(mkIPv4(1, [4]byte{1, 1, 1, 1}, [4]byte{2, 2, 2, 2}, 0, 0, 0)); !ok || id != "icmp:1.1.1.1>2.2.2.2" {
		t.Fatalf("icmp: %q %v", id, ok)
	}
}

type rwc struct {
	in  *bytes.Reader
	out bytes.Buffer
}

func (r *rwc) Read(p []byte) (int, error)  { return r.in.Read(p) }
func (r *rwc) Write(p []byte) (int, error) { return r.out.Write(p) }
func (r *rwc) Close() error                { return nil }

// The desktop TUN stack's tunnel connection feeds the topology.
func TestFlowL3ConnRecordsTraffic(t *testing.T) {
	tr := testTracker()
	reply := mkIPv4(6, [4]byte{10, 9, 8, 7}, [4]byte{10, 1, 2, 3}, 443, 50000, 100)
	c := &flowL3Conn{ReadWriteCloser: &rwc{in: bytes.NewReader(reply)}, t: tr}
	out := mkIPv4(6, [4]byte{10, 1, 2, 3}, [4]byte{10, 9, 8, 7}, 50000, 443, 20)
	if _, err := c.Write(out); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 2000)
	if _, err := c.Read(buf); err != nil && err != io.EOF {
		t.Fatal(err)
	}
	ev, ok := tr.snapshot()
	if !ok || len(ev.Flows) != 1 {
		t.Fatalf("flows: %+v %v", ev.Flows, ok)
	}
	f := ev.Flows[0]
	if f.Host != "10.9.8.7" || f.Route != routeVPN || f.Conns != 1 || f.Up != int64(len(out)) || f.Down != int64(len(reply)) {
		t.Fatalf("flow: %+v", f)
	}
}

// With packet-level VPN accounting the dialer's "-> VPN" lines are ignored
// (they would double count), while DIRECT / PROXY lines still show.
func TestObserveLogSkipsVPNLinesWhenPacketVPN(t *testing.T) {
	tr := testTracker()
	tr.setPacketVPN(true)
	tr.observeLog("10.0.0.1:80 -> VPN")
	tr.observeLog("1.2.3.4:443 -> PROXY[127.0.0.1:7890]")
	ev, _ := tr.snapshot()
	if len(ev.Flows) != 1 || ev.Flows[0].Route != routeProxy {
		t.Fatalf("flows: %+v", ev.Flows)
	}
	tr2 := testTracker()
	tr2.observeLog("10.0.0.1:80 -> VPN")
	ev, _ = tr2.snapshot()
	if len(ev.Flows) != 1 || ev.Flows[0].Route != routeVPN {
		t.Fatalf("proxy mode flows: %+v", ev.Flows)
	}
}
