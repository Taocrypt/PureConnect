// Command zjuconnect-core is the process the ZJU Connect Flutter app talks
// to. It embeds the upstream zju-connect engine and exposes it over a
// JSON-lines protocol on stdin/stdout (see protocol.go).
//
// It is built from inside the upstream module tree (core/build.sh copies this
// directory to <zju-connect>/cmd/zjuconnect-core) so it can reuse upstream's
// internal packages unchanged.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	stdlog "log"
	"net"
	"os"
	"sync"
	"time"

	"github.com/mythologyli/zju-connect/client/atrust"
	"github.com/mythologyli/zju-connect/internal/hook_func"
)

// Set with -ldflags "-X main.coreVersion=... -X main.upstreamVersion=..."
var (
	coreVersion     = "dev"
	upstreamVersion = "unknown"
)

func main() {
	var protocolIn io.Reader = os.Stdin
	var protocolOut io.Writer = os.Stdout
	// --dial host:port --token T: the protocol runs over a loopback TCP
	// connection back to the UI instead of stdin/stdout. Used when the core
	// is started elevated (Windows UAC, macOS admin prompt), where the UI
	// can't hold the process' pipes. Closing the connection stops the core,
	// exactly like closing stdin.
	if addr, token := dialArgs(os.Args[1:]); addr != "" {
		conn, err := net.DialTimeout("tcp", addr, 15*time.Second)
		if err != nil {
			fmt.Fprintln(os.Stderr, "dial UI:", err)
			os.Exit(3)
		}
		if _, err := fmt.Fprintf(conn, "%s\n", token); err != nil {
			os.Exit(3)
		}
		protocolIn, protocolOut = conn, conn
	}
	// Anything that writes to os.Stdout directly (debug hex dumps, loggers
	// created with log.NewLogger) goes to stderr so the protocol stays clean.
	os.Stdout = os.Stderr

	em := newEmitter(protocolOut)
	stdlog.SetFlags(stdlog.Ltime)
	stdlog.SetOutput(&logWriter{em: em})
	flows = newFlowTracker(em)
	startTrafficLoop(em)

	em.emit(Event{Type: "hello", Version: coreVersion + " (zju-connect " + upstreamVersion + ")", ProtocolVersion: protocolVersion})

	var handler *uiChallengeHandler
	var handlerMu sync.Mutex
	var shutdownOnce sync.Once
	var lastErr string
	var lastErrMu sync.Mutex
	hub := em.hub
	shutdown := func(code int) {
		shutdownOnce.Do(func() {
			em.state("stopping", nil)
			handlerMu.Lock()
			if handler != nil {
				handler.cancelAll()
			}
			handlerMu.Unlock()
			// Lightweight mode: put the system proxy back first (no UI will).
			lastErrMu.Lock()
			le := lastErr
			lastErrMu.Unlock()
			hub.finish(code, le, em.hasPrimary() || hub.clientCount() > 0)
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			done := make(chan []error, 1)
			go func() { done <- hook_func.ExecTerminalFunc(ctx) }()
			select {
			case errs := <-done:
				for _, err := range errs {
					em.log("warning", "shutdown: "+err.Error())
				}
			case <-ctx.Done():
				em.log("warning", "shutdown timed out")
			}
			em.state("stopped", nil)
			hub.closeClients()
			os.Exit(code)
		})
	}
	fail := func(err error) {
		lastErrMu.Lock()
		lastErr = err.Error()
		lastErrMu.Unlock()
		em.state("error", err)
	}

	// A dead tunnel (e.g. kicked offline) ends the session cleanly.
	setFatalHook(func(err error) {
		fail(err)
		go shutdown(1)
	})

	commands := make(chan Command, 4)
	// dispatch handles one command from the starting UI (primary) or a
	// re-attached one. Quick ones run here; the rest queue for the loop below.
	dispatch := func(cmd Command, primary bool) {
		switch cmd.Cmd {
		case "stop":
			go shutdown(0)
		case "probe":
			go runProbe(em, cmd.ID, cmd.Targets)
		case "challenge_response":
			handlerMu.Lock()
			h := handler
			handlerMu.Unlock()
			if h != nil {
				h.deliver(cmd.ID, cmd.Response)
			}
		case "detach":
			port, err := hub.detach(cmd.Token, cmd.Restore, primary)
			if err != nil {
				em.emit(Event{Type: "result", Error: err.Error()})
			} else {
				em.log("info", "lightweight mode: core keeps running without the UI")
				em.emit(Event{Type: "detached", OK: true, Port: port, PID: os.Getpid()})
			}
		default:
			commands <- cmd
		}
	}
	hub.onClient = func(c net.Conn) {
		readCommands(c, em, func(cmd Command) { dispatch(cmd, false) })
	}
	go func() {
		readCommands(protocolIn, em, func(cmd Command) { dispatch(cmd, true) })
		if hub.isDetached() {
			// Lightweight mode: the UI exited on purpose; keep the VPN up.
			em.dropPrimary()
			return
		}
		// The UI went away: finish queued commands, then exit (never outlive it).
		close(commands)
	}()

	started := false
	for cmd := range commands {
		switch cmd.Cmd {
		case "version":
			em.emit(Event{Type: "result", OK: true, Version: coreVersion + " (zju-connect " + upstreamVersion + ")"})

		case "auth_info":
			conf, err := loadConfig(cmd.Config)
			if err != nil {
				em.emit(Event{Type: "result", Error: err.Error()})
				continue
			}
			info, err := atrust.GetAuthInfoList(conf.ServerAddress, conf.ServerPort, conf.BindInterface,
				conf.AutoDetectInterface, conf.LocalDNSServer, conf.DebugTLSLogFile)
			if err != nil {
				em.emit(Event{Type: "result", Error: err.Error()})
				continue
			}
			raw, _ := json.Marshal(info)
			em.emit(Event{Type: "auth_info", OK: true, AuthInfo: raw})

		case "trust_device":
			conf, err := loadConfig(cmd.Config)
			if err == nil && conf.ClientDataFile == "" {
				err = errors.New("client data file is required for trust/untrust device")
			}
			var data []byte
			if err == nil {
				data, err = os.ReadFile(conf.ClientDataFile)
			}
			if err == nil {
				err = atrust.SetTrusted(conf.ServerAddress, conf.ServerPort, data, cmd.Trust, conf.BindInterface,
					conf.AutoDetectInterface, conf.LocalDNSServer, conf.DebugTLSLogFile)
			}
			if err != nil {
				em.emit(Event{Type: "result", Error: err.Error()})
			} else {
				em.emit(Event{Type: "result", OK: true})
			}

		case "start":
			if started {
				em.log("error", "start: a session is already running")
				continue
			}
			started = true
			conf, err := loadConfig(cmd.Config)
			if err != nil {
				fail(err)
				shutdown(2)
			}
			h := newUIChallengeHandler(em, cmd.WorkDir)
			handlerMu.Lock()
			handler = h
			handlerMu.Unlock()
			em.state("connecting", nil)
			opts := startOptions{Tun: cmd.Tun, TunFDSocket: cmd.TunFDSocket, WorkDir: cmd.WorkDir}
			if err := safeRun(func() error { return runSession(em, conf, opts, h) }); err != nil {
				fail(err)
				shutdown(1)
			}
			// Services are running; keep serving challenge responses and stop.

		default:
			em.log("error", fmt.Sprintf("unknown command %q", cmd.Cmd))
		}
	}
	shutdown(0)
}

// readCommands decodes one JSON command per line until r ends.
func readCommands(r io.Reader, em *emitter, handle func(Command)) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for sc.Scan() {
		var cmd Command
		if err := json.Unmarshal(sc.Bytes(), &cmd); err != nil {
			em.log("error", "bad command: "+err.Error())
			continue
		}
		handle(cmd)
	}
}

func safeRun(f func() error) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("panic: %v", r)
		}
	}()
	return f()
}

// dialArgs reads "--dial host:port" and "--token T" (or -dial/-token, with
// "=" too). Only loopback addresses are accepted.
func dialArgs(args []string) (addr, token string) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		key, val, hasVal := a, "", false
		if j := indexByte(a, '='); j >= 0 {
			key, val, hasVal = a[:j], a[j+1:], true
		}
		if !hasVal && i+1 < len(args) {
			val = args[i+1]
		}
		switch key {
		case "--dial", "-dial":
			addr = val
		case "--token", "-token":
			token = val
		default:
			continue
		}
		if !hasVal {
			i++
		}
	}
	if host, _, err := net.SplitHostPort(addr); err != nil || (host != "127.0.0.1" && host != "::1" && host != "localhost") {
		return "", ""
	}
	return addr, token
}

func indexByte(s string, c byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == c {
			return i
		}
	}
	return -1
}
