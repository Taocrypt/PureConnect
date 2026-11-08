package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"github.com/knadh/koanf/providers/structs"
	"github.com/knadh/koanf/v2"
	"github.com/mythologyli/zju-connect/configs"
)

var domainPattern = regexp.MustCompile(`^[a-zA-Z\d-]+(\.[a-zA-Z\d-]+)*\.[a-zA-Z]{2,}$`)

// mapProvider feeds an already-decoded JSON object to koanf.
type mapProvider map[string]any

func (m mapProvider) ReadBytes() ([]byte, error)    { return nil, errors.New("not supported") }
func (m mapProvider) Read() (map[string]any, error) { return m, nil }

// legacy keys still accepted by upstream's TOML loader
var configAliases = map[string]string{
	"disable_zju_dns": "disable_remote_dns",
	"zju_dns_server":  "remote_dns_server",
}

// loadConfig decodes the UI's JSON config. Keys are the same snake_case keys
// as upstream's config.toml (see config.toml.example); unknown keys are
// rejected, missing keys take upstream's defaults.
func loadConfig(raw json.RawMessage) (configs.Config, error) {
	k := koanf.New(".")
	if err := k.Load(structs.Provider(configs.Default(), "koanf"), nil); err != nil {
		return configs.Config{}, fmt.Errorf("load defaults: %w", err)
	}
	allowed := map[string]struct{}{}
	for _, key := range k.Keys() {
		allowed[key] = struct{}{}
	}
	// collections are allowed even though their defaults are empty
	for _, key := range []string{"port_forwarding", "custom_dns", "custom_proxy_domain", "mac_addresses"} {
		allowed[key] = struct{}{}
	}

	m := map[string]any{}
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &m); err != nil {
			return configs.Config{}, fmt.Errorf("parse config: %w", err)
		}
	}
	for legacy, canonical := range configAliases {
		if v, ok := m[legacy]; ok {
			if _, dup := m[canonical]; !dup {
				m[canonical] = v
			}
			delete(m, legacy)
		}
	}
	for key := range m {
		if _, ok := allowed[key]; !ok {
			return configs.Config{}, fmt.Errorf("unknown configuration key %q", key)
		}
	}
	if err := k.Load(mapProvider(m), nil); err != nil {
		return configs.Config{}, fmt.Errorf("load config: %w", err)
	}

	var cfg configs.Config
	if err := k.UnmarshalWithConf("", &cfg, koanf.UnmarshalConf{Tag: "koanf"}); err != nil {
		return configs.Config{}, fmt.Errorf("decode config: %w", err)
	}
	if cfg.ServerAddress == "" {
		if cfg.Protocol == "atrust" {
			cfg.ServerAddress = "vpn.zju.edu.cn"
		} else {
			cfg.ServerAddress = "rvpn.zju.edu.cn"
		}
	}
	zjuServerWorkaround(&cfg)
	// Upstream only understands socks:// and http://.
	cfg.DialDirectProxy = strings.TrimSpace(cfg.DialDirectProxy)
	for _, p := range []string{"socks5h://", "socks5://"} {
		if strings.HasPrefix(cfg.DialDirectProxy, p) {
			cfg.DialDirectProxy = "socks://" + strings.TrimPrefix(cfg.DialDirectProxy, p)
		}
	}
	cfg.DialDirectProxy = strings.TrimSuffix(cfg.DialDirectProxy, "/")
	return cfg, validateConfig(cfg)
}

// --- copied from upstream init.go (package main there, not importable) ---

func zjuServerWorkaround(cfg *configs.Config) {
	if cfg.Protocol == "atrust" && cfg.ServerAddress == "rvpn.zju.edu.cn" {
		cfg.ServerAddress = "vpn.zju.edu.cn"
	} else if cfg.Protocol == "easyconnect" && cfg.ServerAddress == "vpn.zju.edu.cn" {
		cfg.ServerAddress = "rvpn.zju.edu.cn"
	}
}

func validateConfig(cfg configs.Config) error {
	if cfg.Protocol != "easyconnect" && cfg.Protocol != "atrust" {
		return fmt.Errorf("unsupported VPN protocol: %s", cfg.Protocol)
	}
	if cfg.ServerPort < 1 || cfg.ServerPort > 65535 {
		return fmt.Errorf("invalid VPN server port: %d", cfg.ServerPort)
	}
	for _, f := range cfg.PortForwardingList {
		if f.NetworkType != "tcp" && f.NetworkType != "udp" {
			return fmt.Errorf("port forwarding: unknown network type %q", f.NetworkType)
		}
		if f.BindAddress == "" || f.RemoteAddress == "" {
			return errors.New("port forwarding: bind and remote address are required")
		}
	}
	for _, e := range cfg.CustomDNSList {
		if e.HostName == "" || e.IP == "" {
			return errors.New("custom DNS: host name and IP are required")
		}
	}
	for _, d := range cfg.CustomProxyDomain {
		if !domainPattern.MatchString(d) {
			return fmt.Errorf("%s is not a valid domain", d)
		}
	}
	return nil
}

func validateConnectConfig(cfg configs.Config) error {
	if cfg.Protocol == "easyconnect" {
		if (cfg.Username == "" || cfg.Password == "") && cfg.TwfID == "" {
			return errors.New("username and password are required")
		}
		return nil
	}
	var primary bool
	switch cfg.AuthType {
	case "auth/psw":
		primary = cfg.Username != "" && cfg.Password != ""
	case "auth/smsCheckCode":
		primary = cfg.Phone != ""
	default:
		return nil
	}
	debug := cfg.SID != "" && cfg.DeviceID != "" && cfg.ResourceFile != ""
	if !primary && !debug {
		return errors.New("missing credentials for the selected aTrust auth type")
	}
	return nil
}
