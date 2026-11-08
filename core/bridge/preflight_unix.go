//go:build !windows && !android

package main

import (
	"errors"
	"os"
)

// preflightTun fails fast, before logging in, when the TUN device and its
// routes can't be set up (they need root).
func preflightTun() error {
	if os.Geteuid() != 0 {
		return errors.New("TUN mode needs root (administrator) rights")
	}
	return nil
}
