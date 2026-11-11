package main

import "runtime"

// runtimeMemory: memory the Go runtime holds from the OS (minus what it has
// handed back), the fallback when the process RSS is not readable.
func runtimeMemory() uint64 {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	if m.Sys > m.HeapReleased {
		return m.Sys - m.HeapReleased
	}
	return m.Sys
}
