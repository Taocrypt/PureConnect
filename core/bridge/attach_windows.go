//go:build windows

package main

import (
	"os"
	"syscall"

	"golang.org/x/sys/windows/registry"
)

func ignoreHangup() {
	if devnull, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0); err == nil {
		os.Stdout, os.Stderr = devnull, devnull
	}
}

var procInternetSetOption = syscall.NewLazyDLL("wininet.dll").NewProc("InternetSetOptionW")

// restoreWinProxy writes the per-user WinINet proxy back, like the runner's
// WriteProxy, and tells running browsers to re-read it.
func restoreWinProxy(p *WinProxy) error {
	k, err := registry.OpenKey(registry.CURRENT_USER,
		`Software\Microsoft\Windows\CurrentVersion\Internet Settings`, registry.SET_VALUE)
	if err != nil {
		return err
	}
	enable := uint32(0)
	if p.Enable != 0 {
		enable = 1
	}
	_ = k.SetDWordValue("ProxyEnable", enable)
	_ = k.SetStringValue("ProxyServer", p.Server)
	_ = k.SetStringValue("ProxyOverride", p.Bypass)
	if p.AutoConfigURL != nil {
		_ = k.SetStringValue("AutoConfigURL", *p.AutoConfigURL)
	} else {
		_ = k.DeleteValue("AutoConfigURL")
	}
	_ = k.Close()
	if procInternetSetOption.Find() == nil {
		const settingsChanged, refresh = 39, 37
		_, _, _ = procInternetSetOption.Call(0, settingsChanged, 0, 0)
		_, _, _ = procInternetSetOption.Call(0, refresh, 0, 0)
	}
	return nil
}
