//go:build !linux && !windows

package main

// processRSS: macOS has no cgo-free RSS query; the Go runtime's own view of
// its memory is close for a pure-Go process.
func processRSS() uint64 { return runtimeMemory() }
