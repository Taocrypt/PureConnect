//go:build !android

package main

import (
	"errors"
	"fmt"

	"github.com/mythologyli/zju-connect/client"
	"github.com/mythologyli/zju-connect/configs"
	"github.com/mythologyli/zju-connect/log"
	"github.com/mythologyli/zju-connect/stack"
	"github.com/mythologyli/zju-connect/stack/tun"
)

func runAndroidTun(em *emitter, conf configs.Config, opts startOptions, vpnClient client.Client, r resources) error {
	return errors.New("android_fd TUN mode is only available on Android")
}

// newSystemTunStack creates upstream's TUN device (needs root/administrator)
// and installs the same routes upstream main.go would.
func newSystemTunStack(conf configs.Config, vpnClient client.Client, r resources) (stack.Stack, error) {
	s, err := tun.NewStack(vpnClient, conf.DNSHijack, conf.FakeIP, r.ipResources)
	if err != nil {
		return nil, fmt.Errorf("TUN stack setup error (run as root/administrator): %w", err)
	}
	for _, route := range routesFor(conf, r, false) {
		log.Printf("Add route to %s", route)
		_ = s.AddRoute(route)
	}
	return s, nil
}
