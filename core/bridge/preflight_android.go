//go:build android

package main

// Android TUN comes from the VpnService; nothing to check here.
func preflightTun() error { return nil }
