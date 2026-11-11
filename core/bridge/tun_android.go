//go:build android

package main

import (
	"errors"
	"fmt"
	"net"
	"os"
	"syscall"
	"time"

	"github.com/mythologyli/zju-connect/client"
	"github.com/mythologyli/zju-connect/configs"
	"github.com/mythologyli/zju-connect/stack"
)

const androidMTU = 1400

// runAndroidTun hands the tunnel parameters to the Android VpnService, waits
// for it to pass the TUN fd over an abstract unix socket (SCM_RIGHTS), then
// pumps packets with upstream's Android TUN stack.
func runAndroidTun(em *emitter, conf configs.Config, opts startOptions, vpnClient client.Client, r resources) error {
	if opts.TunFDSocket == "" {
		return errors.New("tun_fd_socket is required for android_fd mode")
	}
	_, dns, secondary := remoteDNS(conf, vpnClient)
	info := sessionInfo(conf, vpnClient, r, "android_tun")
	info.DNSServer = dns
	info.SecondaryDNS = secondary
	if conf.DialDirectProxy != "" {
		// Full takeover: everything enters the TUN; campus resources go to
		// the tunnel, the rest to the front proxy.
		info.Routes = []string{"0.0.0.0/0"}
		info.FullTakeover = true
		if info.DNSServer == "" {
			info.DNSServer = "223.5.5.5"
			info.SecondaryDNS = "119.29.29.29"
		}
	}
	info.MTU = androidMTU
	em.emit(Event{Type: "tun_request", Session: info})

	fd, err := receiveFD(opts.TunFDSocket, 30*time.Second)
	if err != nil {
		return fmt.Errorf("receive TUN fd: %w", err)
	}

	l3, err := vpnClient.NewL3Conn()
	if err != nil {
		return fmt.Errorf("open L3 tunnel: %w", err)
	}
	// A dead tunnel ends the session with its reason (session_guard.go).
	l3 = newGuardL3Conn(l3)
	fp, err := parseFrontProxy(conf.DialDirectProxy)
	if err != nil {
		l3.Close()
		return err
	}
	if fp != nil {
		em.log("info", "External proxy "+fp.url()+": non-campus traffic goes through it")
		proxyStatusHook = func(ok bool, msg string) {
			em.emit(Event{Type: "proxy_status", OK: ok, Message: fp.url(), Error: msg})
		}
		if err := fp.probe(); err != nil {
			fp.failed("probe", err)
		}
	}
	p, err := newAndroidPump(os.NewFile(uintptr(fd), "tun"), l3, r.ipResources, fp)
	if err != nil {
		l3.Close()
		return fmt.Errorf("front proxy stack: %w", err)
	}
	if vip, err := vpnClient.IP(); err == nil {
		ps, err := newProbeStack(vip, net.ParseIP(info.DNSServer), p.index, p.l3, &p.l3Mu)
		if err != nil {
			em.log("warning", "connectivity test unavailable: "+err.Error())
		} else {
			ps.fp = fp
			p.probe = ps
			setProbeDialer(ps.dial)
		}
	}
	go func() {
		p.run()
		em.log("info", "TUN stack stopped")
		em.state("error", errors.New("tunnel closed"))
	}()

	em.emit(Event{Type: "session", Session: info})
	em.state("connected", nil)
	return nil
}

func receiveFD(name string, timeout time.Duration) (int, error) {
	deadline := time.Now().Add(timeout)
	var conn net.Conn
	var err error
	for time.Now().Before(deadline) {
		conn, err = net.Dial("unix", "@"+name)
		if err == nil {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	if err != nil {
		return -1, err
	}
	defer conn.Close()
	uc := conn.(*net.UnixConn)
	_ = uc.SetReadDeadline(deadline)
	buf := make([]byte, 1)
	oob := make([]byte, syscall.CmsgSpace(4))
	_, oobn, _, _, err := uc.ReadMsgUnix(buf, oob)
	if err != nil {
		return -1, err
	}
	msgs, err := syscall.ParseSocketControlMessage(oob[:oobn])
	if err != nil {
		return -1, err
	}
	for _, m := range msgs {
		fds, err := syscall.ParseUnixRights(&m)
		if err == nil && len(fds) > 0 {
			return fds[0], nil
		}
	}
	return -1, errors.New("no file descriptor received")
}

// newSystemTunStack: desktop-style TUN is not available on Android (use
// android_fd mode through the VpnService instead).
func newSystemTunStack(conf configs.Config, vpnClient client.Client, r resources) (stack.Stack, error) {
	return nil, errors.New("tun_mode is not supported on Android; the app uses VpnService (android_fd) instead")
}
