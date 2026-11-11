package main

import (
	"sync/atomic"
	"time"

	"github.com/mythologyli/zju-connect/underlay"
)

// Traffic through the core: bytes on the underlay connections to the VPN
// server. Reset whenever a new connection starts; a "traffic" event is
// emitted every second while connected (with the core's memory use).

var trafficActive atomic.Bool

func trafficOnState(state string) {
	switch state {
	case "connecting":
		underlay.ResetTraffic()
		trafficActive.Store(false)
	case "connected":
		trafficActive.Store(true)
	case "stopping", "stopped", "error":
		trafficActive.Store(false)
	}
}

func startTrafficLoop(em *emitter) {
	go func() {
		t := time.NewTicker(time.Second)
		defer t.Stop()
		var lastTx, lastRx uint64
		last := time.Now()
		for now := range t.C {
			tx, rx := underlay.Traffic()
			if !trafficActive.Load() {
				lastTx, lastRx, last = tx, rx, now
				continue
			}
			secs := now.Sub(last).Seconds()
			if secs <= 0 {
				secs = 1
			}
			var txRate, rxRate uint64
			if tx >= lastTx {
				txRate = uint64(float64(tx-lastTx) / secs)
			}
			if rx >= lastRx {
				rxRate = uint64(float64(rx-lastRx) / secs)
			}
			lastTx, lastRx, last = tx, rx, now
			em.emit(Event{Type: "traffic", Traffic: &TrafficInfo{Tx: tx, Rx: rx, TxRate: txRate, RxRate: rxRate, Mem: processRSS()}})
		}
	}()
}
