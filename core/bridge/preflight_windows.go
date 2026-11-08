//go:build windows

package main

import (
	"errors"
	"os"
	"path/filepath"

	"golang.org/x/sys/windows"
)

// preflightTun fails fast, before logging in, when the TUN device can't be
// created: wintun needs administrator rights and wintun.dll next to this exe
// (golang.zx2c4.com/wireguard loads it from the application directory).
func preflightTun() error {
	if !windows.GetCurrentProcessToken().IsElevated() {
		return errors.New("TUN mode needs administrator rights (accept the UAC prompt)")
	}
	exe, err := os.Executable()
	if err != nil {
		return nil
	}
	dll := filepath.Join(filepath.Dir(exe), "wintun.dll")
	if _, err := os.Stat(dll); err != nil {
		return errors.New("wintun.dll is missing next to zjuconnect-core.exe; reinstall PureConnect")
	}
	return nil
}
