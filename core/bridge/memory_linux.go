//go:build linux

package main

import (
	"os"
	"strconv"
	"strings"
)

// processRSS: resident set size of the core process (Linux and Android).
func processRSS() uint64 {
	b, err := os.ReadFile("/proc/self/statm")
	if err != nil {
		return runtimeMemory()
	}
	f := strings.Fields(string(b))
	if len(f) < 2 {
		return runtimeMemory()
	}
	pages, err := strconv.ParseUint(f[1], 10, 64)
	if err != nil {
		return runtimeMemory()
	}
	return pages * uint64(os.Getpagesize())
}
