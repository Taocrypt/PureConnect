//go:build android

package main

// Front ("upstream") proxy for Android full takeover.
//
// When a front proxy (e.g. Clash's local mixed port) is configured, the
// VpnService routes everything into our TUN. Packets that match the sangfor
// IP resources go to the L3 tunnel as before; everything else is handed to a
// small gVisor netstack that terminates TCP and dials the destination through
// the front proxy (SOCKS5 or HTTP CONNECT). UDP DNS is relayed directly from
// this process (which is excluded from the VPN); other UDP goes through the
// proxy's SOCKS5 UDP ASSOCIATE when it offers one, otherwise directly.

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/proxy"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
	"gvisor.dev/gvisor/pkg/waiter"
)

const fallbackNIC tcpip.NICID = 1

type frontProxy struct {
	kind string // socks | http
	addr string // host:port

	// health: collapse the flood of per-connection failures into one
	// "proxy down" report, a periodic summary, and a "recovered" report.
	mu        sync.Mutex
	down      bool
	downSince time.Time
	fails     int
	lastLog   time.Time
	watching  bool
}

// proxyStatusHook reports external proxy health changes to the UI.
var proxyStatusHook func(ok bool, msg string)

func (f *frontProxy) url() string { return f.kind + "://" + f.addr }

func (f *frontProxy) failed(target string, err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.fails++
	if !f.down {
		f.down = true
		f.downSince = time.Now()
		f.lastLog = time.Now()
		f.startWatch()
		f.fails = 0
		log.Printf("External proxy %s unreachable (%v); non-campus connections fail until it is back. If Clash was in VPN/TUN mode it stopped when this VPN took over: switch it to proxy-only and start it again.", f.url(), err)
		if proxyStatusHook != nil {
			proxyStatusHook(false, err.Error())
		}
		return
	}
	if time.Since(f.lastLog) >= 30*time.Second {
		log.Printf("External proxy %s still unreachable: %d connections failed in the last %ds (latest %s)", f.url(), f.fails, int(time.Since(f.lastLog).Seconds()), target)
		f.lastLog = time.Now()
		f.fails = 0
	}
}

// succeeded records a connection through the proxy that was started at
// [started]. A dial begun before the proxy went down can still finish after
// (the proxy app was shutting down), so it proves nothing; recovery is only
// announced once a fresh handshake to the proxy works.
func (f *frontProxy) succeeded(started time.Time) {
	f.mu.Lock()
	down, since := f.down, f.downSince
	f.mu.Unlock()
	if !down || started.Before(since) {
		return
	}
	if f.probe() != nil {
		return
	}
	f.markUp()
}

func (f *frontProxy) markUp() {
	f.mu.Lock()
	defer f.mu.Unlock()
	if !f.down {
		return
	}
	f.down = false
	log.Printf("External proxy %s is reachable again (%d failures since last report)", f.url(), f.fails)
	f.fails = 0
	if proxyStatusHook != nil {
		proxyStatusHook(true, "")
	}
}

// startWatch (mu held) re-checks a down proxy every few seconds, so recovery
// is noticed even with no traffic, and only from a real handshake.
func (f *frontProxy) startWatch() {
	if f.watching {
		return
	}
	f.watching = true
	go func() {
		ok := 0
		for {
			time.Sleep(3 * time.Second)
			f.mu.Lock()
			down := f.down
			if !down {
				f.watching = false
			}
			f.mu.Unlock()
			if !down {
				return
			}
			if f.probe() == nil {
				ok++
			} else {
				ok = 0
			}
			// Two good handshakes in a row: the app is really back.
			if ok >= 2 {
				f.markUp()
			}
		}
	}()
}

// probe checks that a proxy of the right kind answers on the address: a
// listening port alone is not enough while the proxy app shuts down.
func (f *frontProxy) probe() error {
	c, err := net.DialTimeout("tcp", f.addr, 2*time.Second)
	if err != nil {
		return err
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(2 * time.Second))
	if f.kind == "socks" {
		if _, err := c.Write([]byte{5, 1, 0}); err != nil {
			return err
		}
		b := make([]byte, 2)
		if _, err := io.ReadFull(c, b); err != nil {
			return err
		}
		if b[0] != 5 || b[1] == 0xff {
			return fmt.Errorf("not a SOCKS5 proxy")
		}
		return nil
	}
	fmt.Fprintf(c, "CONNECT 1.1.1.1:443 HTTP/1.1\r\nHost: 1.1.1.1:443\r\n\r\n")
	b := make([]byte, 5)
	if _, err := io.ReadFull(c, b); err != nil {
		return err
	}
	if string(b) != "HTTP/" {
		return fmt.Errorf("not an HTTP proxy")
	}
	return nil
}

// parseFrontProxy accepts socks://, socks5://, socks5h:// and http:// URLs.
func parseFrontProxy(s string) (*frontProxy, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil, nil
	}
	for _, p := range []string{"socks5h://", "socks5://", "socks://"} {
		if strings.HasPrefix(s, p) {
			return &frontProxy{kind: "socks", addr: strings.TrimPrefix(s, p)}, nil
		}
	}
	if strings.HasPrefix(s, "http://") {
		return &frontProxy{kind: "http", addr: strings.TrimSuffix(strings.TrimPrefix(s, "http://"), "/")}, nil
	}
	return nil, fmt.Errorf("unsupported front proxy %q (use socks5:// or http://)", s)
}

func (f *frontProxy) dial(ctx context.Context, target string) (net.Conn, error) {
	d := &net.Dialer{Timeout: 10 * time.Second}
	if f.kind == "socks" {
		sd, err := proxy.SOCKS5("tcp", f.addr, nil, d)
		if err != nil {
			return nil, err
		}
		if cd, ok := sd.(proxy.ContextDialer); ok {
			return cd.DialContext(ctx, "tcp", target)
		}
		return sd.Dial("tcp", target)
	}
	c, err := d.DialContext(ctx, "tcp", f.addr)
	if err != nil {
		return nil, err
	}
	_ = c.SetDeadline(time.Now().Add(10 * time.Second))
	fmt.Fprintf(c, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", target, target)
	br := bufio.NewReader(c)
	resp, err := http.ReadResponse(br, &http.Request{Method: http.MethodConnect})
	if err != nil {
		c.Close()
		return nil, err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		c.Close()
		return nil, fmt.Errorf("front proxy CONNECT: %s", resp.Status)
	}
	_ = c.SetDeadline(time.Time{})
	if br.Buffered() > 0 {
		return &bufConn{Conn: c, r: br}, nil
	}
	return c, nil
}

type bufConn struct {
	net.Conn
	r *bufio.Reader
}

func (c *bufConn) Read(p []byte) (int, error) { return c.r.Read(p) }

// fallbackStack terminates non-resource traffic.
type fallbackStack struct {
	s     *stack.Stack
	ep    *channel.Endpoint
	fp    *frontProxy
	out   io.Writer // TUN
	outMu *sync.Mutex
	ctx   context.Context
	stop  context.CancelFunc
}

func newFallbackStack(fp *frontProxy, out io.Writer, outMu *sync.Mutex, mtu uint32) (*fallbackStack, error) {
	s := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
	})
	ep := channel.New(512, mtu, "")
	if err := s.CreateNIC(fallbackNIC, ep); err != nil {
		return nil, errors.New(err.String())
	}
	s.SetPromiscuousMode(fallbackNIC, true)
	s.SetSpoofing(fallbackNIC, true)
	s.SetRouteTable([]tcpip.Route{{Destination: header.IPv4EmptySubnet, NIC: fallbackNIC}})
	sack := tcpip.TCPSACKEnabled(true)
	s.SetTransportProtocolOption(tcp.ProtocolNumber, &sack)

	ctx, cancel := context.WithCancel(context.Background())
	f := &fallbackStack{s: s, ep: ep, fp: fp, out: out, outMu: outMu, ctx: ctx, stop: cancel}

	tf := tcp.NewForwarder(s, 0, 2048, f.handleTCP)
	s.SetTransportProtocolHandler(tcp.ProtocolNumber, tf.HandlePacket)
	uf := udp.NewForwarder(s, f.handleUDP)
	s.SetTransportProtocolHandler(udp.ProtocolNumber, uf.HandlePacket)

	go f.writeLoop()
	return f, nil
}

func (f *fallbackStack) close() {
	f.stop()
	f.ep.Close()
	f.s.Close()
}

// inject hands one raw IPv4 packet from the TUN to the netstack.
func (f *fallbackStack) inject(pkt []byte) {
	b := make([]byte, len(pkt))
	copy(b, pkt)
	pb := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(b)})
	f.ep.InjectInbound(header.IPv4ProtocolNumber, pb)
	pb.DecRef()
}

func (f *fallbackStack) writeLoop() {
	for {
		pb := f.ep.ReadContext(f.ctx)
		if pb == nil {
			return
		}
		v := pb.ToView()
		data := v.AsSlice()
		f.outMu.Lock()
		_, err := f.out.Write(data)
		f.outMu.Unlock()
		v.Release()
		pb.DecRef()
		if err != nil {
			return
		}
	}
}

func (f *fallbackStack) handleTCP(r *tcp.ForwarderRequest) {
	id := r.ID()
	dstIP := net.IP(id.LocalAddress.AsSlice()).String()
	target := net.JoinHostPort(dstIP, strconv.Itoa(int(id.LocalPort)))
	connID := "tcp:" + strconv.Itoa(int(id.RemotePort)) + ">" + target

	started := time.Now()
	ctx, cancel := context.WithTimeout(f.ctx, 10*time.Second)
	remote, err := f.fp.dial(ctx, target)
	cancel()
	if err != nil {
		if isProxyUnreachable(err) {
			f.fp.failed(target, err)
		} else {
			log.Printf("%s -> external proxy failed: %v", target, err)
		}
		r.Complete(true)
		return
	}
	go f.fp.succeeded(started)
	var wq waiter.Queue
	ep, terr := r.CreateEndpoint(&wq)
	if terr != nil {
		remote.Close()
		r.Complete(true)
		return
	}
	r.Complete(false)
	local := gonet.NewTCPConn(&wq, ep)
	flows.record(dstIP, connID, routeProxy, 0)
	go relay(local, remote, dstIP)
}

func relay(local, remote net.Conn, dstIP string) {
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		n, _ := io.Copy(remote, local)
		flows.addBytes(dstIP, routeProxy, n, 0)
		if c, ok := remote.(interface{ CloseWrite() error }); ok {
			_ = c.CloseWrite()
		} else {
			_ = remote.Close()
		}
	}()
	go func() {
		defer wg.Done()
		n, _ := io.Copy(local, remote)
		flows.addBytes(dstIP, routeProxy, 0, n)
		_ = local.Close()
	}()
	wg.Wait()
	_ = local.Close()
	_ = remote.Close()
}

// handleUDP relays DNS directly; other UDP goes through the external proxy
// (SOCKS5 UDP ASSOCIATE) or, when it cannot carry UDP, directly.
func (f *fallbackStack) handleUDP(r *udp.ForwarderRequest) bool {
	id := r.ID()
	if id.LocalPort != 53 {
		var wq waiter.Queue
		ep, terr := r.CreateEndpoint(&wq)
		if terr != nil {
			return true
		}
		local := gonet.NewUDPConn(&wq, ep)
		target := net.JoinHostPort(net.IP(id.LocalAddress.AsSlice()).String(), strconv.Itoa(int(id.LocalPort)))
		go f.relayUDP(local, target)
		return true
	}
	var wq waiter.Queue
	ep, terr := r.CreateEndpoint(&wq)
	if terr != nil {
		return true
	}
	local := gonet.NewUDPConn(&wq, ep)
	server := net.JoinHostPort(net.IP(id.LocalAddress.AsSlice()).String(), "53")
	go func() {
		defer local.Close()
		buf := make([]byte, 4096)
		for {
			_ = local.SetReadDeadline(time.Now().Add(30 * time.Second))
			n, err := local.Read(buf)
			if err != nil {
				return
			}
			q := append([]byte(nil), buf[:n]...)
			go func() {
				c, err := net.DialTimeout("udp", server, 5*time.Second)
				if err != nil {
					return
				}
				defer c.Close()
				_ = c.SetDeadline(time.Now().Add(5 * time.Second))
				if _, err := c.Write(q); err != nil {
					return
				}
				resp := make([]byte, 4096)
				m, err := c.Read(resp)
				if err != nil {
					return
				}
				parseDNSAnswers(resp[:m])
				_, _ = local.Write(resp[:m])
			}()
		}
	}()
	return true
}

const udpIdle = 90 * time.Second

var udpDirectOnce sync.Once

func (f *fallbackStack) relayUDP(local *gonet.UDPConn, target string) {
	defer local.Close()
	var remote net.Conn
	if f.fp != nil && f.fp.kind == "socks" {
		started := time.Now()
		c, err := socksUDPAssociate(f.fp.addr, target)
		switch {
		case err == nil:
			remote = c
			go f.fp.succeeded(started)
		case isProxyUnreachable(err):
			f.fp.failed(target, err)
			return // never leak around a dead proxy
		default:
			udpDirectOnce.Do(func() {
				log.Printf("External proxy %s does not relay UDP (%v); UDP goes directly instead", f.fp.url(), err)
			})
		}
	}
	if remote == nil {
		c, err := net.DialTimeout("udp", target, 5*time.Second)
		if err != nil {
			return
		}
		remote = c
	}
	defer remote.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		buf := make([]byte, 65535)
		for {
			_ = remote.SetReadDeadline(time.Now().Add(udpIdle))
			n, err := remote.Read(buf)
			if err != nil {
				return
			}
			if _, err := local.Write(buf[:n]); err != nil {
				return
			}
		}
	}()
	buf := make([]byte, 65535)
	for {
		_ = local.SetReadDeadline(time.Now().Add(udpIdle))
		n, err := local.Read(buf)
		if err != nil {
			break
		}
		if _, err := remote.Write(buf[:n]); err != nil {
			break
		}
	}
	remote.Close()
	<-done
}

// socksUDPConn wraps a SOCKS5 UDP relay for one destination.
type socksUDPConn struct {
	net.Conn          // UDP to the relay
	ctrl     net.Conn // TCP control connection; the association dies with it
	header   []byte
}

func (c *socksUDPConn) Write(p []byte) (int, error) {
	pkt := make([]byte, 0, len(c.header)+len(p))
	pkt = append(append(pkt, c.header...), p...)
	if _, err := c.Conn.Write(pkt); err != nil {
		return 0, err
	}
	return len(p), nil
}

func (c *socksUDPConn) Read(p []byte) (int, error) {
	buf := make([]byte, 65535)
	for {
		n, err := c.Conn.Read(buf)
		if err != nil {
			return 0, err
		}
		if n < 4 || buf[2] != 0 {
			continue // fragmented or malformed
		}
		off := 4
		switch buf[3] {
		case 1:
			off += 4
		case 4:
			off += 16
		case 3:
			if n < 5 {
				continue
			}
			off += 1 + int(buf[4])
		default:
			continue
		}
		off += 2
		if off > n {
			continue
		}
		return copy(p, buf[off:n]), nil
	}
}

func (c *socksUDPConn) Close() error {
	_ = c.ctrl.Close()
	return c.Conn.Close()
}

func socksAddr(hostport string) ([]byte, error) {
	host, port, err := net.SplitHostPort(hostport)
	if err != nil {
		return nil, err
	}
	pn, err := strconv.Atoi(port)
	if err != nil {
		return nil, err
	}
	var b []byte
	if ip := net.ParseIP(host); ip != nil {
		if ip4 := ip.To4(); ip4 != nil {
			b = append([]byte{1}, ip4...)
		} else {
			b = append([]byte{4}, ip.To16()...)
		}
	} else {
		b = append([]byte{3, byte(len(host))}, host...)
	}
	return append(b, byte(pn>>8), byte(pn)), nil
}

func socksUDPAssociate(proxyAddr, target string) (net.Conn, error) {
	ctrl, err := net.DialTimeout("tcp", proxyAddr, 5*time.Second)
	if err != nil {
		return nil, err
	}
	fail := func(e error) (net.Conn, error) { ctrl.Close(); return nil, e }
	_ = ctrl.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := ctrl.Write([]byte{5, 1, 0}); err != nil {
		return fail(err)
	}
	r := make([]byte, 262)
	if _, err := io.ReadFull(ctrl, r[:2]); err != nil {
		return fail(err)
	}
	if r[0] != 5 || r[1] != 0 {
		return fail(fmt.Errorf("socks5 auth method 0x%02x not supported", r[1]))
	}
	if _, err := ctrl.Write([]byte{5, 3, 0, 1, 0, 0, 0, 0, 0, 0}); err != nil {
		return fail(err)
	}
	if _, err := io.ReadFull(ctrl, r[:4]); err != nil {
		return fail(err)
	}
	if r[1] != 0 {
		return fail(fmt.Errorf("socks5 UDP ASSOCIATE rejected (0x%02x)", r[1]))
	}
	var relayHost string
	switch r[3] {
	case 1:
		if _, err := io.ReadFull(ctrl, r[:4]); err != nil {
			return fail(err)
		}
		relayHost = net.IP(r[:4]).String()
	case 4:
		if _, err := io.ReadFull(ctrl, r[:16]); err != nil {
			return fail(err)
		}
		relayHost = net.IP(r[:16]).String()
	case 3:
		if _, err := io.ReadFull(ctrl, r[:1]); err != nil {
			return fail(err)
		}
		l := int(r[0])
		if _, err := io.ReadFull(ctrl, r[:l]); err != nil {
			return fail(err)
		}
		relayHost = string(r[:l])
	default:
		return fail(fmt.Errorf("socks5 bad address type 0x%02x", r[3]))
	}
	if _, err := io.ReadFull(ctrl, r[:2]); err != nil {
		return fail(err)
	}
	relayPort := int(r[0])<<8 | int(r[1])
	if ip := net.ParseIP(relayHost); ip == nil || ip.IsUnspecified() {
		relayHost, _, _ = net.SplitHostPort(proxyAddr)
	}
	_ = ctrl.SetDeadline(time.Time{})
	hdr, err := socksAddr(target)
	if err != nil {
		return fail(err)
	}
	uc, err := net.DialTimeout("udp", net.JoinHostPort(relayHost, strconv.Itoa(relayPort)), 5*time.Second)
	if err != nil {
		return fail(err)
	}
	return &socksUDPConn{Conn: uc, ctrl: ctrl, header: append([]byte{0, 0, 0}, hdr...)}, nil
}

// isProxyUnreachable: the proxy itself is not answering (vs. the proxy
// refusing one destination).
func isProxyUnreachable(err error) bool {
	m := err.Error()
	return strings.Contains(m, "connection refused") || strings.Contains(m, "dial tcp 127.") ||
		strings.Contains(m, "network is unreachable") || strings.Contains(m, "no route to host")
}
