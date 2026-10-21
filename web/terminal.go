package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// The read-only terminal (cx web --terminal): ttyd showing one session's
// screen, through `cx open --view`, which attaches tmux read-only. ttyd runs
// here, on the machine cx web runs on, listening on a Unix socket in a 0700
// directory, so there is no port for anything else to reach; the browser
// only ever talks to cx web, which proxies /term/<id>/ to that socket behind
// its own sign-in.
//
// ttyd is started per view and with --once, so it exits when its one viewer
// goes; one nobody connects to is killed after termIdle. These are children
// of a request, not a loop: nothing here runs unless someone asked to watch.

const (
	maxTerms = 4
	termIdle = time.Minute
)

type term struct {
	id, target string
	proxy      *httputil.ReverseProxy
	stop       func()
	done       chan struct{}

	mu        sync.Mutex
	connected bool
}

type termManager struct {
	cfg config
	// spawn starts whatever listens on sock; ttyd, except in tests.
	spawn func(ctx context.Context, sock, id, target string) (stop func(), done chan struct{}, err error)

	mu    sync.Mutex
	dir   string
	terms map[string]*term
}

func newTermManager(cfg config) *termManager {
	m := &termManager{cfg: cfg, terms: map[string]*term{}}
	m.spawn = m.ttyd
	return m
}

// ttyd starts ttyd for one view. Read-only is ttyd's default (no -W), and
// `cx open --view` is read-only again on the tmux side, so either alone
// would keep a watcher from typing.
func (m *termManager) ttyd(_ context.Context, sock, id, target string) (func(), chan struct{}, error) {
	cmd := exec.Command(m.cfg.ttydPath,
		"--once",
		"--interface", sock,
		"--base-path", "/term/"+id,
		"--client-option", "titleFixed=cx: "+target,
		"--client-option", "disableLeaveAlert=true",
		m.cfg.cxPath, "--no-color", "open", "--view", target)
	cmd.Stdin = nil
	cmd.Stdout, cmd.Stderr = io.Discard, io.Discard
	cmd.Env = append(os.Environ(), "CX_PICKER=none")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return nil, nil, err
	}
	done := make(chan struct{})
	go func() { _ = cmd.Wait(); close(done) }()
	stop := func() { _ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM) }
	return stop, done, nil
}

var errTooMany = errors.New("too many terminal views open; close one first")

func (m *termManager) start(target string) (*term, error) {
	m.mu.Lock()
	if len(m.terms) >= maxTerms {
		m.mu.Unlock()
		return nil, errTooMany
	}
	if m.dir == "" {
		d, err := os.MkdirTemp("", "cx-web-term-") // 0700
		if err != nil {
			m.mu.Unlock()
			return nil, err
		}
		m.dir = d
	}
	dir := m.dir
	m.mu.Unlock()

	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return nil, err
	}
	id := hex.EncodeToString(b)
	sock := filepath.Join(dir, id[:12]+".sock") // short: a socket path has a length limit
	stop, done, err := m.spawn(context.Background(), sock, id, target)
	if err != nil {
		return nil, err
	}
	// Ready when the socket is there. A ttyd that exits first (a bad
	// argument, or the session is gone) is reported as such.
	ready := false
	for i := 0; i < 100 && !ready; i++ {
		if _, err := os.Stat(sock); err == nil {
			ready = true
			break
		}
		select {
		case <-done:
			return nil, errors.New("ttyd exited before it was ready")
		case <-time.After(30 * time.Millisecond):
		}
	}
	if !ready {
		stop()
		return nil, errors.New("ttyd did not start")
	}

	t := &term{id: id, target: target, stop: stop, done: done}
	t.proxy = &httputil.ReverseProxy{
		Director: func(r *http.Request) {
			r.URL.Scheme = "http"
			r.URL.Host = "ttyd"
		},
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", sock)
			},
		},
		ErrorLog: nil,
	}
	m.mu.Lock()
	m.terms[id] = t
	m.mu.Unlock()

	go func() {
		<-done
		m.mu.Lock()
		delete(m.terms, id)
		m.mu.Unlock()
		_ = os.Remove(sock)
	}()
	time.AfterFunc(termIdle, func() {
		t.mu.Lock()
		c := t.connected
		t.mu.Unlock()
		if !c {
			stop()
		}
	})
	return t, nil
}

func (m *termManager) get(id string) *term {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.terms[id]
}

func (m *termManager) closeAll() {
	m.mu.Lock()
	ts := make([]*term, 0, len(m.terms))
	for _, t := range m.terms {
		ts = append(ts, t)
	}
	dir := m.dir
	m.mu.Unlock()
	for _, t := range ts {
		t.stop()
	}
	if dir != "" {
		_ = os.RemoveAll(dir)
	}
}

// termStart is POST /api/term {target}.
func (s *server) termStart(w http.ResponseWriter, r *http.Request) {
	if !s.cfg.terminal {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "the terminal view is off; start cx web with --terminal"})
		return
	}
	var b struct {
		Target string `json:"target"`
	}
	if !readJSON(w, r, &b) {
		return
	}
	if !validTarget(b.Target) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "not a target"})
		return
	}
	t, err := s.terms.start(b.Target)
	if errors.Is(err, errTooMany) {
		writeJSON(w, http.StatusConflict, map[string]any{"error": err.Error()})
		return
	}
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]any{"error": "cannot start the terminal view: " + err.Error()})
		return
	}
	logAction("view", b.Target, cxResult{}, "")
	writeJSON(w, http.StatusOK, map[string]any{"url": "/term/" + t.id + "/"})
}

// termProxy serves /term/<id>/..., signed in like every other route. Its
// WebSocket is a GET that a page on another site could open with this
// browser's cookie were it not SameSite=Strict; the Origin check is the
// second lock on that door.
func (s *server) termProxy(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.authenticate(w, r); !ok {
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "read-only", http.StatusMethodNotAllowed)
		return
	}
	rest := strings.TrimPrefix(r.URL.Path, "/term/")
	id, _, _ := strings.Cut(rest, "/")
	t := s.terms.get(id)
	if t == nil {
		http.Error(w, "no such terminal view; it ends when its tab is closed", http.StatusNotFound)
		return
	}
	if strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
		if !sameOrigin(r) {
			http.Error(w, "cross-origin request refused", http.StatusForbidden)
			return
		}
		t.mu.Lock()
		t.connected = true
		t.mu.Unlock()
		// The server's timeouts are for requests; a terminal is watched for
		// as long as its tab is open.
		rc := http.NewResponseController(w)
		_ = rc.SetReadDeadline(time.Time{})
		_ = rc.SetWriteDeadline(time.Time{})
	}
	t.proxy.ServeHTTP(w, r)
}
