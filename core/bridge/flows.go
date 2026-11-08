package main

// Connection topology for the dashboard (device -> destination -> route).
//
// Two sources feed the tracker:
//   - upstream's own log lines (proxy / desktop TUN): "host -> ip" from the
//     resolver, "ip:port -> VPN|DIRECT|PROXY[..]" from the dialer and
//     "ACL: refusing ip:port/net" from the client-side whitelist;
//   - the Android TUN pump (tun_android.go), which sees every packet.
//
// Every flowInterval the tracker emits a "flows" event with the destinations
// seen in the last flowWindow, aggregated by (destination, route).

import (
	"net"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	flowWindow   = time.Minute
	flowInterval = 2 * time.Second
	flowMaxRows  = 40
)

// Route names understood by the UI.
const (
	routeVPN     = "vpn"
	routeDirect  = "direct"
	routeProxy   = "proxy"
	routeBlocked = "blocked"
)

type FlowInfo struct {
	Host  string `json:"host"`
	Route string `json:"route"`
	Conns int    `json:"conns"`
	Up    int64  `json:"up,omitempty"`
	Down  int64  `json:"down,omitempty"`
}

type flowKey struct{ dst, route string }

type flowEntry struct {
	conns map[string]time.Time // connection id -> last seen
	up    int64
	down  int64
	seen  time.Time
}

type flowTracker struct {
	em      *emitter
	mu      sync.Mutex
	names   map[string]string // ip -> host name
	flows   map[flowKey]*flowEntry
	byDst   map[string]flowKey // ip -> last key (for down-bytes attribution)
	dirty   bool
	stop    chan struct{}
	stopped bool
}

var flows *flowTracker

func newFlowTracker(em *emitter) *flowTracker {
	t := &flowTracker{em: em, names: map[string]string{}, flows: map[flowKey]*flowEntry{}, byDst: map[string]flowKey{}, stop: make(chan struct{})}
	go t.loop()
	return t
}

func (t *flowTracker) reset() {
	if t == nil {
		return
	}
	t.mu.Lock()
	t.names = map[string]string{}
	t.flows = map[flowKey]*flowEntry{}
	t.byDst = map[string]flowKey{}
	t.dirty = true
	t.mu.Unlock()
}

func (t *flowTracker) learnName(ip, host string) {
	if t == nil || ip == "" || host == "" || ip == host {
		return
	}
	t.mu.Lock()
	t.names[ip] = strings.TrimSuffix(host, ".")
	t.mu.Unlock()
}

// record notes one packet/connection. id identifies the connection (5-tuple or
// a unique log line id); bytes counts upload.
func (t *flowTracker) record(dstIP, id, route string, up int64) {
	if t == nil {
		return
	}
	now := time.Now()
	t.mu.Lock()
	defer t.mu.Unlock()
	k := flowKey{dstIP, route}
	e := t.flows[k]
	if e == nil {
		e = &flowEntry{conns: map[string]time.Time{}}
		t.flows[k] = e
	}
	if _, ok := e.conns[id]; !ok {
		t.dirty = true
	}
	e.conns[id] = now
	e.up += up
	e.seen = now
	t.byDst[dstIP] = k
	if up > 0 {
		t.dirty = true
	}
}

// addBytes adds traffic to an existing (dst, route) bucket.
func (t *flowTracker) addBytes(dstIP, route string, up, down int64) {
	if t == nil || up+down == 0 {
		return
	}
	t.mu.Lock()
	if e := t.flows[flowKey{dstIP, route}]; e != nil {
		e.up += up
		e.down += down
		t.dirty = true
	}
	t.mu.Unlock()
}

func (t *flowTracker) recordDown(srcIP string, n int64) {
	if t == nil {
		return
	}
	t.mu.Lock()
	if k, ok := t.byDst[srcIP]; ok {
		if e := t.flows[k]; e != nil {
			e.down += n
			t.dirty = true
		}
	}
	t.mu.Unlock()
}

func (t *flowTracker) loop() {
	tk := time.NewTicker(flowInterval)
	defer tk.Stop()
	for {
		select {
		case <-t.stop:
			return
		case <-tk.C:
			if ev, ok := t.snapshot(); ok {
				t.em.emit(ev)
			}
		}
	}
}

func (t *flowTracker) snapshot() (Event, bool) {
	now := time.Now()
	t.mu.Lock()
	defer t.mu.Unlock()
	agg := map[flowKey]*FlowInfo{}
	for k, e := range t.flows {
		for id, ts := range e.conns {
			if now.Sub(ts) > flowWindow {
				delete(e.conns, id)
				t.dirty = true
			}
		}
		if len(e.conns) == 0 {
			delete(t.flows, k)
			if t.byDst[k.dst] == k {
				delete(t.byDst, k.dst)
			}
			continue
		}
		host := k.dst
		if n, ok := t.names[k.dst]; ok {
			host = n
		}
		ak := flowKey{host, k.route}
		f := agg[ak]
		if f == nil {
			f = &FlowInfo{Host: host, Route: k.route}
			agg[ak] = f
		}
		f.Conns += len(e.conns)
		f.Up += e.up
		f.Down += e.down
	}
	if !t.dirty {
		return Event{}, false
	}
	t.dirty = false
	list := make([]FlowInfo, 0, len(agg))
	for _, f := range agg {
		list = append(list, *f)
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].Conns != list[j].Conns {
			return list[i].Conns > list[j].Conns
		}
		return list[i].Up+list[i].Down > list[j].Up+list[j].Down
	})
	if len(list) > flowMaxRows {
		list = list[:flowMaxRows]
	}
	return Event{Type: "flows", Flows: list}, true
}

// ---------------------------------------------------------------------------
// Upstream log lines
// ---------------------------------------------------------------------------

var (
	reDial    = regexp.MustCompile(`(\S+) -> (VPN|DIRECT|PROXY\[[^\]]*\])$`)
	reResolve = regexp.MustCompile(`(\S+) -> (\d+\.\d+\.\d+\.\d+)(?: \(Fake IP\))?$`)
	reACL     = regexp.MustCompile(`ACL: refusing (\S+)/(\w+)`)
	logSeq    int64
	logSeqMu  sync.Mutex
)

func nextLogID() string {
	logSeqMu.Lock()
	defer logSeqMu.Unlock()
	logSeq++
	return "l" + itoa(logSeq)
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}

func hostOnly(addr string) string {
	if h, _, err := net.SplitHostPort(addr); err == nil {
		return h
	}
	return addr
}

// observeLog extracts topology data from one upstream log line.
func (t *flowTracker) observeLog(line string) {
	if t == nil || !strings.Contains(line, "->") && !strings.Contains(line, "ACL:") {
		return
	}
	if m := reACL.FindStringSubmatch(line); m != nil {
		t.record(hostOnly(m[1]), nextLogID(), routeBlocked, 0)
		return
	}
	if m := reDial.FindStringSubmatch(line); m != nil {
		route := routeVPN
		switch {
		case m[2] == "DIRECT":
			route = routeDirect
		case strings.HasPrefix(m[2], "PROXY"):
			route = routeProxy
		}
		t.record(hostOnly(m[1]), nextLogID(), route, 0)
		return
	}
	if m := reResolve.FindStringSubmatch(line); m != nil {
		t.learnName(m[2], m[1])
	}
}
