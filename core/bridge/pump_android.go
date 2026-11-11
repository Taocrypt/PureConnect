//go:build android

package main

// Packet pump between the Android TUN fd and the sangfor L3 tunnel.
//
// Upstream's Android stack forwards every TCP/UDP packet to the server. A
// packet to a destination outside the server-issued IP resources makes
// sangfor terminate the whole session (cmd 0x08 SHUTDOWN), so - like the
// official client and upstream's dialer ACL - we drop those here. The pump
// also feeds the connection topology.

import (
	"encoding/binary"
	"io"
	"log"
	"net"
	"sync"
	"time"

	"github.com/mythologyli/zju-connect/client"
	"github.com/mythologyli/zju-connect/internal/ipresource"
)

type androidPump struct {
	tun    io.ReadWriteCloser
	l3     io.ReadWriteCloser
	index  *ipresource.Index // nil: no whitelist known, forward everything
	tunMu  sync.Mutex
	l3Mu   sync.Mutex
	probe  *probeStack // connectivity tests, nil if unavailable
	fb     *fallbackStack // front proxy for non-resource traffic (full takeover)
	warnMu sync.Mutex
	warned map[string]time.Time
}

func newAndroidPump(tun, l3 io.ReadWriteCloser, res []client.IPResource, fp *frontProxy) (*androidPump, error) {
	p := &androidPump{tun: tun, l3: l3, warned: map[string]time.Time{}}
	if res != nil {
		p.index = ipresource.New(res)
	}
	if fp != nil {
		if p.index == nil {
			// Without a whitelist we cannot tell campus traffic apart.
			p.index = ipresource.New([]client.IPResource{})
		}
		fb, err := newFallbackStack(fp, tun, &p.tunMu, androidMTU)
		if err != nil {
			return nil, err
		}
		p.fb = fb
	}
	return p, nil
}

func (p *androidPump) run() {
	defer p.l3.Close()
	if p.probe != nil {
		defer p.probe.close()
	}
	if p.fb != nil {
		defer p.fb.close()
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		buf := make([]byte, 65535)
		for {
			n, err := p.l3.Read(buf)
			if err != nil {
				log.Printf("Error occurred while reading from VPN server: %v", err)
				return
			}
			pkt := buf[:n]
			if p.probe != nil && p.probe.owns(pkt) {
				p.probe.inject(pkt)
				continue
			}
			p.observeInbound(pkt)
			p.tunMu.Lock()
			_, err = p.tun.Write(pkt)
			p.tunMu.Unlock()
			if err != nil {
				log.Printf("Error occurred while writing to TUN: %v", err)
				return
			}
		}
	}()

	buf := make([]byte, 65535)
	for {
		select {
		case <-done:
			return
		default:
		}
		n, err := p.tun.Read(buf)
		if err != nil {
			log.Printf("Error occurred while reading from TUN: %v", err)
			return
		}
		pkt := buf[:n]
		if n < 20 || pkt[0]>>4 != 4 {
			continue
		}
		ihl := int(pkt[0]&0x0f) * 4
		if ihl < 20 || n < ihl {
			continue
		}
		var proto string
		switch pkt[9] {
		case 6:
			proto = "tcp"
		case 17:
			proto = "udp"
		default:
			continue // upstream drops non TCP/UDP too
		}
		if n < ihl+4 {
			continue
		}
		srcPort := binary.BigEndian.Uint16(pkt[ihl:])
		dstPort := int(binary.BigEndian.Uint16(pkt[ihl+2:]))
		dst := net.IP(pkt[16:20])
		dstS := dst.String()
		conn := proto + ":" + itoa(int64(srcPort)) + ">" + dstS + ":" + itoa(int64(dstPort))

		if p.index != nil {
			if _, ok := p.index.Match(dst, proto, dstPort); !ok {
				if p.fb != nil {
					p.fb.inject(pkt)
					continue
				}
				flows.record(dstS, conn, routeBlocked, 0)
				p.warnDrop(dstS, proto, dstPort)
				continue
			}
		}
		flows.record(dstS, conn, routeVPN, int64(n))
		p.l3Mu.Lock()
		_, err = p.l3.Write(pkt)
		p.l3Mu.Unlock()
		if err != nil {
			log.Printf("Error occurred while writing to VPN server: %v", err)
			return
		}
	}
}

func (p *androidPump) warnDrop(dst, proto string, port int) {
	key := dst + "/" + proto + ":" + itoa(int64(port))
	p.warnMu.Lock()
	defer p.warnMu.Unlock()
	if t, ok := p.warned[key]; ok && time.Since(t) < time.Minute {
		return
	}
	p.warned[key] = time.Now()
	log.Printf("ACL: dropping %s:%d/%s — not in server IP resources (would trigger tunnel SHUTDOWN)", dst, port, proto)
}

// observeInbound counts download bytes and learns names from DNS answers
// that come back through the tunnel.
func (p *androidPump) observeInbound(pkt []byte) {
	flows.observeInboundPacket(pkt)
}
