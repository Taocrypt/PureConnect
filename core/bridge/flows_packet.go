package main

// Packet-level topology: used where traffic reaches the core as raw IP
// packets instead of through upstream's dialer (Android VpnService pump and
// the desktop TUN stack), so no "ip:port -> VPN" log line is ever written.

import (
	"encoding/binary"
	"net"

	"golang.org/x/net/dns/dnsmessage"
)

// outboundConn parses an IPv4 packet headed for the tunnel. It returns the
// destination IP, a connection id (protocol + 5-tuple) and ok=false for
// anything that is not an IPv4 TCP/UDP/ICMP packet.
func outboundConn(pkt []byte) (dst, id string, ok bool) {
	if len(pkt) < 20 || pkt[0]>>4 != 4 {
		return "", "", false
	}
	ihl := int(pkt[0]&0x0f) * 4
	if ihl < 20 || len(pkt) < ihl {
		return "", "", false
	}
	dst = net.IP(pkt[16:20]).String()
	src := net.IP(pkt[12:16]).String()
	switch pkt[9] {
	case 6, 17:
		if len(pkt) < ihl+4 {
			return "", "", false
		}
		proto := "tcp"
		if pkt[9] == 17 {
			proto = "udp"
		}
		sp := binary.BigEndian.Uint16(pkt[ihl:])
		dp := binary.BigEndian.Uint16(pkt[ihl+2:])
		return dst, proto + ":" + src + ":" + itoa(int64(sp)) + ">" + dst + ":" + itoa(int64(dp)), true
	case 1:
		return dst, "icmp:" + src + ">" + dst, true
	}
	return "", "", false
}

// observeOutboundPacket records one packet sent into the tunnel.
func (t *flowTracker) observeOutboundPacket(pkt []byte) {
	if t == nil {
		return
	}
	if dst, id, ok := outboundConn(pkt); ok {
		t.record(dst, id, routeVPN, int64(len(pkt)))
	}
}

// observeInboundPacket counts download bytes and learns names from DNS
// answers that come back through the tunnel.
func (t *flowTracker) observeInboundPacket(pkt []byte) {
	if t == nil || len(pkt) < 20 || pkt[0]>>4 != 4 {
		return
	}
	src := net.IP(pkt[12:16]).String()
	t.recordDown(src, int64(len(pkt)))
	ihl := int(pkt[0]&0x0f) * 4
	if pkt[9] != 17 || len(pkt) < ihl+8 || binary.BigEndian.Uint16(pkt[ihl:]) != 53 {
		return
	}
	parseDNSAnswers(pkt[ihl+8:])
}

func parseDNSAnswers(b []byte) {
	var parser dnsmessage.Parser
	if _, err := parser.Start(b); err != nil {
		return
	}
	q, err := parser.Question()
	if err != nil {
		return
	}
	if err := parser.SkipAllQuestions(); err != nil {
		return
	}
	for {
		h, err := parser.AnswerHeader()
		if err != nil {
			return
		}
		if h.Type == dnsmessage.TypeA {
			a, err := parser.AResource()
			if err != nil {
				return
			}
			flows.learnName(net.IP(a.A[:]).String(), q.Name.String())
			continue
		}
		if err := parser.SkipAnswer(); err != nil {
			return
		}
	}
}
