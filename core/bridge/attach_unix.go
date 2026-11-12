//go:build !windows

package main

import (
	"errors"
	"os"
	"os/signal"
	"syscall"
)

// ignoreHangup keeps a detached core alive once the UI that started it is
// gone: writes to its closed stdout/stderr pipes then fail with EPIPE
// instead of killing the process, and a closing terminal doesn't hang it up.
func ignoreHangup() {
	signal.Ignore(syscall.SIGPIPE, syscall.SIGHUP)
	if devnull, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0); err == nil {
		os.Stdout, os.Stderr = devnull, devnull
	}
}

func restoreWinProxy(*WinProxy) error { return errors.New("not windows") }
