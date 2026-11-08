package main

// JSON-lines protocol between the Flutter UI (or the Android VpnService) and
// zjuconnect-core.
//
//   stdin  (UI -> core): one Command per line
//   stdout (core -> UI): one Event per line
//   stderr            : raw, unstructured output (panics, third-party loggers)
//
// Every stdout line is a complete JSON object, so the reader never has to
// guess where a log message ends.

import (
	"encoding/json"
	"io"
	"strings"
	"sync"
	"time"
)

const protocolVersion = 1

// Command is a request from the UI.
type Command struct {
	Cmd string `json:"cmd"` // start | stop | challenge_response | auth_info | trust_device | version

	// start / auth_info / trust_device
	Config json.RawMessage `json:"config,omitempty"`
	// start: "none" (proxy only / desktop TUN via config.tun_mode) or "android_fd"
	Tun         string `json:"tun,omitempty"`
	TunFDSocket string `json:"tun_fd_socket,omitempty"` // abstract unix socket name, android only
	// Directory used for captcha images and other scratch files.
	WorkDir string `json:"work_dir,omitempty"`

	// trust_device
	Trust bool `json:"trust,omitempty"`

	// probe: connectivity test targets (results as "probe" events with ID)
	Targets []ProbeTarget `json:"targets,omitempty"`

	// challenge_response / probe
	ID       int64             `json:"id,omitempty"`
	Response ChallengeResponse `json:"response,omitempty"`
}

// ChallengeResponse carries the user's answer to a Challenge event.
type ChallengeResponse struct {
	Cancel            bool    `json:"cancel,omitempty"`
	Code              string  `json:"code,omitempty"`
	SkipSecondaryAuth bool    `json:"skip_secondary_auth,omitempty"`
	Points            []Point `json:"points,omitempty"`
	Width             int     `json:"width,omitempty"`
	Height            int     `json:"height,omitempty"`
	CallbackURL       string  `json:"callback_url,omitempty"`
}

type Point struct {
	X int `json:"x"`
	Y int `json:"y"`
}

// Event is a message to the UI. Only the fields relevant for Type are set.
type Event struct {
	Type string `json:"type"` // hello | log | state | challenge | session | tun_request | auth_info | result
	Time int64  `json:"time"` // unix millis

	// hello
	Version         string `json:"version,omitempty"`
	ProtocolVersion int    `json:"protocol_version,omitempty"`

	// log
	Level   string `json:"level,omitempty"`
	Message string `json:"message,omitempty"`

	// state: connecting | connected | stopping | stopped | error
	State string `json:"state,omitempty"`
	Error string `json:"error,omitempty"`

	// challenge
	ID        int64  `json:"id,omitempty"`
	Kind      string `json:"kind,omitempty"` // code | text_captcha | click_captcha | external_login
	CodeKind  string `json:"code_kind,omitempty"`
	CanSkip   bool   `json:"can_skip,omitempty"`
	ImagePath string `json:"image_path,omitempty"`
	LoginURL  string `json:"login_url,omitempty"`

	// session / tun_request
	Session *SessionInfo `json:"session,omitempty"`

	// auth_info
	AuthInfo json.RawMessage `json:"auth_info,omitempty"`

	// result (auth_info / trust_device)
	OK bool `json:"ok,omitempty"`

	// flows: connection topology of the last couple of minutes
	Flows []FlowInfo `json:"flows,omitempty"`

	// traffic: bytes through the core since this connection started
	Traffic *TrafficInfo `json:"traffic,omitempty"`

	// probe: one connectivity test result
	Probe *ProbeResult `json:"probe,omitempty"`
}

// TrafficInfo counts bytes on the connections to the VPN server.
type TrafficInfo struct {
	Tx     uint64 `json:"tx"`
	Rx     uint64 `json:"rx"`
	TxRate uint64 `json:"tx_rate"` // bytes/s
	RxRate uint64 `json:"rx_rate"`
}

type SessionInfo struct {
	Protocol        string            `json:"protocol"`
	Server          string            `json:"server"`
	IP              string            `json:"ip"`
	DNSServer       string            `json:"dns_server,omitempty"`
	SecondaryDNS    string            `json:"secondary_dns,omitempty"`
	Routes          []string          `json:"routes"`
	Stack           string            `json:"stack"` // gvisor | tun | tcptunnel | android_tun
	SocksBind       string            `json:"socks_bind,omitempty"`
	HTTPBind        string            `json:"http_bind,omitempty"`
	DNSServerBind   string            `json:"dns_server_bind,omitempty"`
	Shadowsocks     bool              `json:"shadowsocks,omitempty"`
	PortForwarding  []PortForwardInfo `json:"port_forwarding,omitempty"`
	IPResources     []IPResourceInfo  `json:"ip_resources,omitempty"`
	DomainResources []string          `json:"domain_resources,omitempty"`
	MTU             int               `json:"mtu,omitempty"`
	FullTakeover    bool              `json:"full_takeover,omitempty"`
	WebResources    []WebResource     `json:"web_resources,omitempty"`
	RawResources    string            `json:"raw_resources,omitempty"`
}

type PortForwardInfo struct {
	Network string `json:"network"`
	Bind    string `json:"bind"`
	Remote  string `json:"remote"`
}

type IPResourceInfo struct {
	IPMin    string `json:"ip_min"`
	IPMax    string `json:"ip_max"`
	PortMin  int    `json:"port_min"`
	PortMax  int    `json:"port_max"`
	Protocol string `json:"protocol"`
}

// emitter serialises events onto the protocol channel.
type emitter struct {
	mu  sync.Mutex
	enc *json.Encoder
}

func newEmitter(w io.Writer) *emitter {
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	return &emitter{enc: enc}
}

func (e *emitter) emit(ev Event) {
	ev.Time = time.Now().UnixMilli()
	e.mu.Lock()
	defer e.mu.Unlock()
	_ = e.enc.Encode(ev)
}

func (e *emitter) log(level, msg string) {
	e.emit(Event{Type: "log", Level: level, Message: msg})
}

func (e *emitter) state(state string, err error) {
	trafficOnState(state)
	ev := Event{Type: "state", State: state}
	if err != nil {
		ev.Error = err.Error()
	}
	e.emit(ev)
}

// logWriter adapts the standard logger (used everywhere in zju-connect) to
// "log" events, one per line.
type logWriter struct {
	em  *emitter
	mu  sync.Mutex
	buf strings.Builder
}

func (w *logWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.buf.Write(p)
	s := w.buf.String()
	for {
		i := strings.IndexByte(s, '\n')
		if i < 0 {
			break
		}
		line := strings.TrimRight(s[:i], "\r")
		s = s[i+1:]
		if line != "" {
			flows.observeLog(line)
			w.em.log(levelOf(line), line)
		}
	}
	w.buf.Reset()
	w.buf.WriteString(s)
	return len(p), nil
}

func levelOf(line string) string {
	l := strings.ToLower(line)
	switch {
	case strings.Contains(l, "error"), strings.Contains(l, "failed"), strings.Contains(l, "fatal"):
		return "error"
	case strings.Contains(l, "warn"):
		return "warning"
	default:
		return "info"
	}
}
