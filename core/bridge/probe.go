package main

import (
	"context"
	"errors"
	"net"
	"strconv"
	"sync"
	"time"
)

// Connectivity test for resources: a TCP connect through the tunnel, timed.

// ProbeTarget is one host (domain or IP) and port; port 0 tries 443 then 80.
type ProbeTarget struct {
	Host string `json:"host"`
	Port int    `json:"port,omitempty"`
}

// ProbeResult is the outcome for one target.
type ProbeResult struct {
	Host  string `json:"host"`
	Port  int    `json:"port"`
	OK    bool   `json:"ok"`
	Ms    int64  `json:"ms"`
	Error string `json:"error,omitempty"`
}

// probeDial connects to host:port through the tunnel. Set once connected.
var (
	probeMu   sync.RWMutex
	probeDial func(ctx context.Context, host string, port int) (net.Conn, error)
)

func setProbeDialer(f func(ctx context.Context, host string, port int) (net.Conn, error)) {
	probeMu.Lock()
	probeDial = f
	probeMu.Unlock()
}

// Attempts with growing timeouts: a slow but working site still passes.
var probeTimeouts = []time.Duration{1 * time.Second, 3 * time.Second, 5 * time.Second}

func runProbe(em *emitter, id int64, targets []ProbeTarget) {
	probeMu.RLock()
	dial := probeDial
	probeMu.RUnlock()
	sem := make(chan struct{}, 8)
	var wg sync.WaitGroup
	for _, t := range targets {
		t := t
		wg.Add(1)
		sem <- struct{}{}
		go func() {
			defer wg.Done()
			defer func() { <-sem }()
			res := probeOne(dial, t)
			em.emit(Event{Type: "probe", ID: id, Probe: &res})
		}()
	}
	wg.Wait()
}

func probeOne(dial func(context.Context, string, int) (net.Conn, error), t ProbeTarget) ProbeResult {
	res := ProbeResult{Host: t.Host, Port: t.Port}
	if dial == nil {
		res.Error = "not connected"
		return res
	}
	ports := []int{t.Port}
	if t.Port <= 0 {
		ports = []int{443, 80}
	}
	var lastErr error
	for _, timeout := range probeTimeouts {
		port, ms, err := probeRace(dial, t.Host, ports, timeout)
		if err == nil {
			res.Port, res.OK, res.Ms = port, true, ms
			return res
		}
		lastErr = err
		res.Port = ports[0]
		if !errors.Is(err, context.DeadlineExceeded) && !isTimeout(err) {
			break // refused / unreachable: waiting longer will not help
		}
	}
	if errors.Is(lastErr, context.DeadlineExceeded) || isTimeout(lastErr) {
		res.Error = "timeout"
	} else if lastErr != nil {
		res.Error = lastErr.Error()
	}
	return res
}

// probeRace dials all ports at once and returns the first that connects.
func probeRace(dial func(context.Context, string, int) (net.Conn, error), host string, ports []int, timeout time.Duration) (int, int64, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	type r struct {
		port int
		ms   int64
		err  error
	}
	ch := make(chan r, len(ports))
	start := time.Now()
	for _, port := range ports {
		port := port
		go func() {
			c, err := dial(ctx, host, port)
			ms := time.Since(start).Milliseconds()
			if err == nil {
				c.Close()
			}
			ch <- r{port, ms, err}
		}()
	}
	var firstErr error
	for range ports {
		x := <-ch
		if x.err == nil {
			if x.ms == 0 {
				x.ms = 1
			}
			return x.port, x.ms, nil
		}
		if firstErr == nil || isTimeout(firstErr) {
			firstErr = x.err
		}
	}
	return 0, 0, firstErr
}

func isTimeout(err error) bool {
	var ne net.Error
	return err != nil && (errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &ne) && ne.Timeout()))
}

func hostPort(host string, port int) string { return net.JoinHostPort(host, strconv.Itoa(port)) }
