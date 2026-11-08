//go:build android

package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"

	"github.com/mythologyli/zju-connect/internal/ipresource"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
)

// The core process is outside the VPN, so connectivity tests use a small
// userspace stack of their own on the L3 tunnel. It owns local ports from
// probePortMin up, above Android's ephemeral range (32768-60999), so the pump
// can tell its replies apart from the apps'.

const (
	probeNIC     = 1
	probePortMin = 61000
)

type probeStack struct {
	s     *stack.Stack
	ep    *channel.Endpoint
	vip   net.IP
	dns   net.IP
	index *ipresource.Index
	fp    *frontProxy
	out   io.Writer
	outMu *sync.Mutex
	ctx   context.Context
	stop  context.CancelFunc
}

func newProbeStack(vip, dns net.IP, index *ipresource.Index, out io.Writer, outMu *sync.Mutex) (*probeStack, error) {
	vip = vip.To4()
	if vip == nil {
		return nil, errors.New("no IPv4 virtual address")
	}
	s := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
	})
	ep := channel.New(64, androidMTU, "")
	if err := s.CreateNIC(probeNIC, ep); err != nil {
		return nil, errors.New(err.String())
	}
	if err := s.AddProtocolAddress(probeNIC, tcpip.ProtocolAddress{
		Protocol:          ipv4.ProtocolNumber,
		AddressWithPrefix: tcpip.AddressWithPrefix{Address: tcpip.AddrFromSlice(vip), PrefixLen: 32},
	}, stack.AddressProperties{}); err != nil {
		return nil, errors.New(err.String())
	}
	s.SetRouteTable([]tcpip.Route{{Destination: header.IPv4EmptySubnet, NIC: probeNIC}})
	if err := s.SetPortRange(probePortMin, 65535); err != nil {
		return nil, errors.New(err.String())
	}
	ctx, cancel := context.WithCancel(context.Background())
	p := &probeStack{s: s, ep: ep, vip: vip, dns: dns.To4(), index: index, out: out, outMu: outMu, ctx: ctx, stop: cancel}
	go p.writeLoop()
	return p, nil
}

func (p *probeStack) close() {
	p.stop()
	p.ep.Close()
	p.s.Close()
}

// owns reports whether an inbound tunnel packet is a reply to a probe.
func (p *probeStack) owns(pkt []byte) bool {
	if len(pkt) < 20 || pkt[0]>>4 != 4 || (pkt[9] != 6 && pkt[9] != 17) {
		return false
	}
	ihl := int(pkt[0]&0x0f) * 4
	if len(pkt) < ihl+4 || !net.IP(pkt[16:20]).Equal(p.vip) {
		return false
	}
	return int(pkt[ihl+2])<<8|int(pkt[ihl+3]) >= probePortMin
}

func (p *probeStack) inject(pkt []byte) {
	b := make([]byte, len(pkt))
	copy(b, pkt)
	pb := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(b)})
	p.ep.InjectInbound(header.IPv4ProtocolNumber, pb)
	pb.DecRef()
}

func (p *probeStack) writeLoop() {
	for {
		pb := p.ep.ReadContext(p.ctx)
		if pb == nil {
			return
		}
		v := pb.ToView()
		p.outMu.Lock()
		_, err := p.out.Write(v.AsSlice())
		p.outMu.Unlock()
		v.Release()
		pb.DecRef()
		if err != nil {
			return
		}
	}
}

func (p *probeStack) allowed(ip net.IP, proto string, port int) bool {
	if p.index == nil {
		return true
	}
	_, ok := p.index.Match(ip, proto, port)
	return ok
}

// resolve tries the campus DNS through the tunnel, then plain DNS servers
// reached directly (the core runs outside the VPN and Android gives a Go
// binary no resolv.conf, so the default resolver cannot be used).
func (p *probeStack) resolve(ctx context.Context, host string) (net.IP, error) {
	var lastErr error
	if p.dns != nil && p.allowed(p.dns, "udp", 53) {
		r := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			return gonet.DialUDP(p.s, nil, &tcpip.FullAddress{NIC: probeNIC, Addr: tcpip.AddrFromSlice(p.dns), Port: 53}, ipv4.ProtocolNumber)
		}}
		ip, err := lookup4(ctx, r, host, 2*time.Second)
		if err == nil {
			return ip, nil
		}
		lastErr = err
	}
	servers := []string{}
	if p.dns != nil && !p.allowed(p.dns, "udp", 53) {
		servers = append(servers, p.dns.String())
	}
	servers = append(servers, "223.5.5.5", "119.29.29.29")
	for _, srv := range servers {
		addr := net.JoinHostPort(srv, "53")
		r := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "udp", addr)
		}}
		ip, err := lookup4(ctx, r, host, 2*time.Second)
		if err == nil {
			return ip, nil
		}
		lastErr = err
	}
	return nil, fmt.Errorf("resolve %s: %w", host, lastErr)
}

func lookup4(ctx context.Context, r *net.Resolver, host string, timeout time.Duration) (net.IP, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	ips, err := r.LookupIP(ctx, "ip4", host)
	if err != nil {
		return nil, err
	}
	if len(ips) == 0 {
		return nil, errors.New("no address")
	}
	return ips[0].To4(), nil
}

func (p *probeStack) dial(ctx context.Context, host string, port int) (net.Conn, error) {
	ip := net.ParseIP(host).To4()
	if ip == nil {
		var err error
		if ip, err = p.resolve(ctx, host); err != nil {
			return nil, err
		}
	}
	if !p.allowed(ip, "tcp", port) {
		// Not a tunnel resource: the phone reaches it outside the tunnel
		// (direct, or through the external proxy), so test that path.
		addr := hostPort(ip.String(), port)
		if p.fp != nil {
			return p.fp.dial(ctx, addr)
		}
		var d net.Dialer
		return d.DialContext(ctx, "tcp", addr)
	}
	return gonet.DialContextTCP(ctx, p.s, tcpip.FullAddress{NIC: probeNIC, Addr: tcpip.AddrFromSlice(ip), Port: uint16(port)}, ipv4.ProtocolNumber)
}
