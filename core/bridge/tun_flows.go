package main

// Topology for the desktop TUN stack.
//
// Upstream's TUN stack (stack/tun) forwards packets straight to the L3
// tunnel (or, in TCP tunnel mode, dials client.DialTCP) without going
// through the dialer, so it never writes the "ip:port -> VPN" log lines the
// tracker reads in proxy mode: the topology stayed empty in TUN mode. The
// stack only talks to the VPN through the client.Client it is given, so we
// hand it a client that observes that traffic.

import (
	"context"
	"io"
	"net"

	"github.com/mythologyli/zju-connect/client"
)

type flowClient struct {
	client.Client
	t *flowTracker
}

func newFlowClient(c client.Client, t *flowTracker) client.Client {
	t.setPacketVPN(true)
	return &flowClient{Client: c, t: t}
}

// SetIPUpdateHandler keeps upstream's IP-update hook working (stack/tun on
// Linux and macOS registers one through a type assertion).
func (c *flowClient) SetIPUpdateHandler(h func(net.IP) error) {
	client.RegisterIPUpdateHandler(c.Client, h)
}

func (c *flowClient) NewL3Conn() (io.ReadWriteCloser, error) {
	l3, err := c.Client.NewL3Conn()
	if err != nil {
		return nil, err
	}
	return &flowL3Conn{ReadWriteCloser: l3, t: c.t}, nil
}

func (c *flowClient) DialTCP(ctx context.Context, addr *net.TCPAddr) (net.Conn, error) {
	conn, err := c.Client.DialTCP(ctx, addr)
	if err != nil {
		return nil, err
	}
	dst := addr.IP.String()
	id := "tcp:" + nextLogID()
	c.t.record(dst, id, routeVPN, 0)
	return &flowConn{Conn: conn, t: c.t, dst: dst, id: id}, nil
}

type flowL3Conn struct {
	io.ReadWriteCloser
	t *flowTracker
}

func (c *flowL3Conn) Write(p []byte) (int, error) {
	n, err := c.ReadWriteCloser.Write(p)
	if n > 0 {
		c.t.observeOutboundPacket(p[:n])
	}
	return n, err
}

func (c *flowL3Conn) Read(p []byte) (int, error) {
	n, err := c.ReadWriteCloser.Read(p)
	if n > 0 {
		c.t.observeInboundPacket(p[:n])
	}
	return n, err
}

// flowConn counts a TCP tunnel connection; every read/write keeps it alive
// in the topology window.
type flowConn struct {
	net.Conn
	t       *flowTracker
	dst, id string
}

func (c *flowConn) Write(p []byte) (int, error) {
	n, err := c.Conn.Write(p)
	if n > 0 {
		c.t.record(c.dst, c.id, routeVPN, int64(n))
	}
	return n, err
}

func (c *flowConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	if n > 0 {
		c.t.record(c.dst, c.id, routeVPN, 0)
		c.t.addBytes(c.dst, routeVPN, 0, int64(n))
	}
	return n, err
}
