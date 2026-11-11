package main

// The session flow below follows upstream zju-connect main.go step by step;
// the differences are: errors are returned instead of log.Fatal, the UI
// challenge handler is plugged in, and a "session" event describes the
// result so the UI can show IP, routes and resources.

import (
	"context"
	"crypto"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/mythologyli/zju-connect/client"
	atrustclient "github.com/mythologyli/zju-connect/client/atrust"
	"github.com/mythologyli/zju-connect/client/atrust/auth"
	easyconnectclient "github.com/mythologyli/zju-connect/client/easyconnect"
	"github.com/mythologyli/zju-connect/configs"
	"github.com/mythologyli/zju-connect/dial"
	"github.com/mythologyli/zju-connect/internal/hook_func"
	"github.com/mythologyli/zju-connect/internal/keylog"
	"github.com/mythologyli/zju-connect/log"
	"github.com/mythologyli/zju-connect/resolve"
	"github.com/mythologyli/zju-connect/service"
	"github.com/mythologyli/zju-connect/stack"
	"github.com/mythologyli/zju-connect/stack/gvisor"
	"github.com/mythologyli/zju-connect/stack/tcptunnel"
	"github.com/mythologyli/zju-connect/underlay"
	"golang.org/x/crypto/pkcs12"
	"inet.af/netaddr"
)

type startOptions struct {
	Tun         string // "none" | "android_fd"
	TunFDSocket string
	WorkDir     string
}

type resources struct {
	ipResources     []client.IPResource
	ipSet           *netaddr.IPSet
	domainResources client.DomainResources
	dnsResource     map[string][]net.IP
}

// connectClient performs login and returns a ready VPN client.
func connectClient(conf *configs.Config, opts startOptions, handler *uiChallengeHandler) (client.Client, error) {
	underlayDialer, err := underlay.New(underlay.Options{
		InterfaceName:  conf.BindInterface,
		AutoDetect:     conf.AutoDetectInterface,
		DebugPCAPFile:  conf.DebugPCAPFile,
		LocalDNSServer: conf.LocalDNSServer,
	})
	if err != nil {
		return nil, fmt.Errorf("create underlay dialer: %w", err)
	}
	hook_func.RegisterTerminalFunc("CloseUnderlayDialer", func(ctx context.Context) error {
		return underlayDialer.Close()
	})

	tlsKeyLogWriter, err := keylog.Open(conf.DebugTLSLogFile)
	if err != nil {
		return nil, fmt.Errorf("create TLS key log: %w", err)
	}
	if tlsKeyLogWriter != nil {
		hook_func.RegisterTerminalFunc("CloseTLSKeyLog", func(ctx context.Context) error {
			return tlsKeyLogWriter.Close()
		})
	}
	var keyLog io.Writer
	if tlsKeyLogWriter != nil {
		keyLog = tlsKeyLogWriter
	}

	// The challenge handler writes its own images, but some login paths
	// only ask for a captcha when an output path is configured.
	graphCodeFile := conf.GraphCodeFile
	if graphCodeFile == "" {
		graphCodeFile = filepath.Join(handler.workDir, "graph_code.img")
	}

	var vpnClient client.Client
	switch conf.Protocol {
	case "easyconnect":
		tlsCert := tls.Certificate{}
		if conf.CertFile != "" {
			p12, err := os.ReadFile(conf.CertFile)
			if err != nil {
				return nil, fmt.Errorf("read certificate file: %w", err)
			}
			key, cert, err := pkcs12.Decode(p12, conf.CertPassword)
			if err != nil {
				return nil, fmt.Errorf("decode certificate file: %w", err)
			}
			tlsCert = tls.Certificate{Certificate: [][]byte{cert.Raw}, PrivateKey: key.(crypto.PrivateKey), Leaf: cert}
		}
		ec := easyconnectclient.NewClient(easyconnectclient.Options{
			Server: net.JoinHostPort(conf.ServerAddress, strconv.Itoa(conf.ServerPort)),
			Auth: easyconnectclient.AuthOptions{
				Username:      conf.Username,
				Password:      conf.Password,
				TOTPSecret:    conf.TOTPSecret,
				Certificate:   tlsCert,
				GraphCodeFile: graphCodeFile,
			},
			SessionID:     conf.TwfID,
			TestMultiLine: !conf.DisableMultiLine,
			Resources: easyconnectclient.ResourceOptions{
				Fetch:          !conf.DisableServerConfig,
				IncludeDomains: !conf.SkipDomainResource,
			},
			UnderlayDialer:   underlayDialer,
			TLSKeyLogWriter:  keyLog,
			ChallengeHandler: handler,
		})
		hook_func.RegisterTerminalFunc("CloseVPNClient", func(ctx context.Context) error { ec.Close(); return nil })
		log.Printf("VPN protocol: %s", conf.Protocol)
		if err := ec.Setup(); err != nil {
			return nil, fmt.Errorf("VPN client setup error: %w", err)
		}
		if ec.CanUseTCPTunnel() {
			conf.TCPTunnelMode = true
		}
		vpnClient = ec

	case "atrust":
		var resourceData, clientData []byte
		var err error
		if conf.ResourceFile != "" {
			if resourceData, err = os.ReadFile(conf.ResourceFile); err != nil {
				return nil, fmt.Errorf("read resource file: %w", err)
			}
		}
		if conf.ClientDataFile != "" {
			if clientData, err = os.ReadFile(conf.ClientDataFile); err != nil {
				log.Printf("Read client data file error: %s", err)
				log.Println("Will create a new client data file if log in successfully")
			}
		}
		var loginMethod auth.LoginMethod
		if conf.SID == "" || conf.DeviceID == "" || resourceData == nil {
			loginMethod, err = auth.NewLoginMethod(auth.LoginMethodOptions{
				AuthType:      conf.AuthType,
				Username:      conf.Username,
				Password:      conf.Password,
				Phone:         conf.Phone,
				Domain:        conf.LoginDomain,
				GraphCodeFile: graphCodeFile,
				CASTicket:     conf.CasTicket,
				OAuth2Code:    conf.OAuth2Code,
			})
			if err != nil {
				return nil, fmt.Errorf("configure aTrust login: %w", err)
			}
		}
		at := atrustclient.NewClient(atrustclient.ClientOptions{
			Session: atrustclient.SessionOptions{
				Username:     conf.Username,
				SID:          conf.SID,
				DeviceID:     conf.DeviceID,
				MACAddresses: conf.MACAddresses,
				SignKey:      conf.SignKey,
			},
			UnderlayDialer:  underlayDialer,
			TLSKeyLogWriter: keyLog,
		})
		hook_func.RegisterTerminalFunc("CloseVPNClient", func(ctx context.Context) error { at.Close(); return nil })
		var save func([]byte) error
		if conf.ClientDataFile != "" {
			path := conf.ClientDataFile
			save = func(data []byte) error { return os.WriteFile(path, data, 0o600) }
		}
		log.Printf("VPN protocol: %s", conf.Protocol)
		if _, err := at.Setup(atrustclient.SetupOptions{
			ServerAddress:            conf.ServerAddress,
			ServerPort:               conf.ServerPort,
			LoginMethod:              loginMethod,
			TOTPSecret:               conf.TOTPSecret,
			ClientData:               clientData,
			ResourceData:             resourceData,
			BestNodesRefreshInterval: time.Duration(conf.UpdateBestNodesInterval) * time.Second,
			SessionRefreshInterval:   time.Duration(conf.SessionRefreshInterval) * time.Second,
			SaveClientData:           save,
			ChallengeHandler:         handler,
		}); err != nil {
			return nil, fmt.Errorf("VPN client setup error: %w", err)
		}
		vpnClient = at
	default:
		return nil, fmt.Errorf("unsupported protocol %q", conf.Protocol)
	}
	log.Printf("VPN client started")
	return vpnClient, nil
}

// collectResources gathers server resources and applies the ZJU defaults and
// custom proxy domains exactly as upstream main.go does.
func collectResources(conf configs.Config, vpnClient client.Client) resources {
	var r resources
	var err error
	if r.ipResources, err = vpnClient.IPResources(); err != nil && !conf.DisableServerConfig {
		log.Println("No IP resources")
	}
	if r.ipSet, err = vpnClient.IPSet(); err != nil && !conf.DisableServerConfig {
		log.Println("No IP set")
	}
	if r.domainResources, err = vpnClient.DomainResources(); err != nil && !conf.DisableServerConfig {
		log.Println("No domain resources")
	}
	if r.dnsResource, err = vpnClient.DNSResource(); err != nil && !conf.DisableServerConfig {
		log.Println("No DNS resource")
	}

	if conf.Protocol == "easyconnect" {
		all := client.DomainResource{PortMin: 1, PortMax: 65535, Protocol: "all"}
		if !conf.DisableZJUConfig {
			if r.domainResources == nil {
				r.domainResources = make(client.DomainResources)
			}
			r.domainResources["zju.edu.cn"] = []client.DomainResource{all}
			r.ipResources = append([]client.IPResource{{
				IPMin: net.ParseIP("10.0.0.0"), IPMax: net.ParseIP("10.255.255.255"),
				PortMin: 1, PortMax: 65535, Protocol: "all",
			}}, r.ipResources...)
			b := netaddr.IPSetBuilder{}
			if r.ipSet != nil {
				b.AddSet(r.ipSet)
			}
			b.AddPrefix(netaddr.MustParseIPPrefix("10.0.0.0/8"))
			r.ipSet, _ = b.IPSet()
		}
		for _, d := range conf.CustomProxyDomain {
			if r.domainResources == nil {
				r.domainResources = make(client.DomainResources)
			}
			r.domainResources[d] = append(r.domainResources[d], all)
		}
	}
	return r
}

// routesFor returns the prefixes that should go through the tunnel. Desktop
// TUN follows upstream exactly; Android always needs explicit routes, so it
// falls back to the server's IP set when add_route is off.
func routesFor(conf configs.Config, r resources, android bool) []string {
	var routes []string
	if conf.AddRoute && r.ipSet != nil {
		for _, p := range r.ipSet.Prefixes() {
			routes = append(routes, p.String())
		}
	} else if !conf.DisableZJUConfig && conf.Protocol == "easyconnect" {
		routes = append(routes, "10.0.0.0/8")
	} else if android && r.ipSet != nil {
		for _, p := range r.ipSet.Prefixes() {
			routes = append(routes, p.String())
		}
	}
	if conf.FakeIP {
		routes = append(routes, "198.18.0.0/16")
	}
	return routes
}

func remoteDNS(conf configs.Config, vpnClient client.Client) (useRemote bool, primary, secondary string) {
	useRemote = !conf.DisableRemoteDNS
	primary = conf.RemoteDNSServer
	policy, _ := vpnClient.DNSServers()
	if useRemote && primary == "auto" {
		s, err := vpnClient.DNSServer()
		if err != nil {
			useRemote = false
			primary = "10.10.0.21"
			log.Println("No DNS server provided by server. Disable remote DNS")
		} else {
			primary = s
			log.Printf("Use DNS server %s provided by server", primary)
		}
	}
	secondary = conf.SecondaryDNSServer
	if secondary == "auto" {
		secondary = "114.114.114.114"
		if len(policy) > 1 {
			secondary = policy[1]
		}
	}
	return
}

func sessionInfo(conf configs.Config, vpnClient client.Client, r resources, stackName string) *SessionInfo {
	android := stackName == "android_tun"
	info := &SessionInfo{
		Protocol:      conf.Protocol,
		Server:        net.JoinHostPort(conf.ServerAddress, strconv.Itoa(conf.ServerPort)),
		Stack:         stackName,
		SocksBind:     conf.SocksBind,
		HTTPBind:      conf.HTTPBind,
		DNSServerBind: conf.DNSServerBind,
		Shadowsocks:   conf.ShadowsocksURL != "",
		Routes:        routesFor(conf, r, android),
	}
	if ip, err := vpnClient.IP(); err == nil && ip != nil {
		info.IP = ip.String()
	}
	for _, f := range conf.PortForwardingList {
		info.PortForwarding = append(info.PortForwarding, PortForwardInfo{f.NetworkType, f.BindAddress, f.RemoteAddress})
	}
	for _, res := range r.ipResources {
		info.IPResources = append(info.IPResources, IPResourceInfo{
			IPMin: res.IPMin.String(), IPMax: res.IPMax.String(),
			PortMin: res.PortMin, PortMax: res.PortMax, Protocol: res.Protocol,
		})
	}
	for d := range r.domainResources {
		info.DomainResources = append(info.DomainResources, d)
	}
	info.RawResources = rawResourceList(vpnClient)
	info.WebResources = parseWebResources(info.RawResources)
	return info
}

// runSession logs in and starts every configured service. It returns once
// everything is running; the services keep running until the process exits.
func runSession(em *emitter, conf configs.Config, opts startOptions, handler *uiChallengeHandler) error {
	if err := validateConnectConfig(conf); err != nil {
		return err
	}
	if conf.DebugDump {
		log.EnableDebug()
	}
	if errs := hook_func.ExecInitialFunc(context.Background(), conf); errs != nil {
		return errors.Join(errs...)
	}

	if conf.TUNMode && opts.Tun != "android_fd" {
		if err := preflightTun(); err != nil {
			return err
		}
	}

	vpnClient, err := connectClient(&conf, opts, handler)
	if err != nil {
		return err
	}
	r := collectResources(conf, vpnClient)

	if opts.Tun == "android_fd" {
		return runAndroidTun(em, conf, opts, vpnClient, r)
	}
	// The stacks reach the tunnel through this client so a dead tunnel ends
	// the session with its reason instead of a panic (session_guard.go).
	stackClient := newGuardClient(vpnClient)

	var vpnStack stack.Stack
	stackName := "gvisor"
	switch {
	case conf.TCPTunnelMode:
		stackName = "tcptunnel"
		if vpnStack, err = tcptunnel.NewStack(vpnClient); err != nil {
			return fmt.Errorf("TCP tunnel stack setup error: %w", err)
		}
	case conf.TUNMode:
		stackName = "tun"
		if vpnStack, err = newSystemTunStack(conf, stackClient, r); err != nil {
			return err
		}
	default:
		if vpnStack, err = gvisor.NewStack(stackClient); err != nil {
			return fmt.Errorf("gVisor stack setup error: %w", err)
		}
	}

	useRemoteDNS, remoteDNSServer, secondaryDNSServer := remoteDNS(conf, vpnClient)
	vpnResolver := resolve.NewResolver(vpnStack, remoteDNSServer, secondaryDNSServer, conf.DNSTTL,
		r.domainResources, r.dnsResource, useRemoteDNS)
	hook_func.RegisterTerminalFunc("CloseResolver", func(ctx context.Context) error { vpnResolver.Close(); return nil })
	for _, c := range conf.CustomDNSList {
		ip := net.ParseIP(c.IP)
		if ip == nil {
			log.Printf("Custom DNS for host name %s is invalid, SKIP", c.HostName)
			continue
		}
		vpnResolver.SetPermanentDNS(c.HostName, ip)
		log.Printf("Add custom DNS: %s -> %s", c.HostName, c.IP)
	}
	localResolver := service.NewDnsServer(vpnResolver, []string{remoteDNSServer, conf.SecondaryDNSServer})
	vpnStack.SetupResolve(localResolver)
	vpnStack.SetupIPPool(vpnResolver.IPPool)
	go vpnStack.Run()

	vpnDialer := dial.NewDialer(vpnStack, vpnResolver, r.ipResources, conf.ProxyAll, conf.DialDirectProxy)
	setProbeDialer(func(ctx context.Context, host string, port int) (net.Conn, error) {
		return vpnDialer.Dial(ctx, "tcp", hostPort(host, port))
	})

	if conf.DNSServerBind != "" {
		go service.ServeDNS(conf.DNSServerBind, localResolver)
	}
	if conf.TUNMode {
		if ip, err := vpnClient.IP(); err == nil && ip != nil {
			go service.ServeDNS(ip.String()+":53", localResolver)
		}
	}
	if conf.SocksBind != "" {
		go service.ServeSocks5(conf.SocksBind, vpnDialer, vpnResolver, conf.SocksUser, conf.SocksPasswd)
	}
	if conf.HTTPBind != "" {
		go service.ServeHTTP(conf.HTTPBind, vpnDialer)
	}
	if conf.ShadowsocksURL != "" {
		go service.ServeShadowsocks(vpnDialer, conf.ShadowsocksURL)
	}
	for _, f := range conf.PortForwardingList {
		switch f.NetworkType {
		case "tcp":
			go service.ServeTCPForwarding(vpnDialer.Dial, f.BindAddress, f.RemoteAddress)
		case "udp":
			go service.ServeUDPForwarding(vpnStack, f.BindAddress, f.RemoteAddress)
		}
	}
	if !conf.DisableKeepAlive {
		if conf.KeepAliveURL == "" && !useRemoteDNS {
			log.Println("Keep alive is disabled because remote DNS is disabled, and no KeepAliveURL is provided")
		} else {
			ctx, cancel := context.WithCancel(context.Background())
			hook_func.RegisterTerminalFunc("CloseKeepAlive", func(context.Context) error { cancel(); return nil })
			go service.KeepAlive(ctx, vpnResolver, vpnDialer, conf.KeepAliveURL)
		}
	}

	info := sessionInfo(conf, vpnClient, r, stackName)
	info.DNSServer = remoteDNSServer
	info.SecondaryDNS = secondaryDNSServer
	em.emit(Event{Type: "session", Session: info})
	em.state("connected", nil)
	return nil
}
