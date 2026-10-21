package main

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"strings"
	"testing"
)

// fakeTtyd stands in for ttyd: an HTTP server on the Unix socket it is
// given, answering with the path it was asked for, so a test can tell the
// proxy reached it and with what.
func fakeTtyd(t *testing.T) func(context.Context, string, string, string) (func(), chan struct{}, error) {
	return func(_ context.Context, sock, _, target string) (func(), chan struct{}, error) {
		ln, err := net.Listen("unix", sock)
		if err != nil {
			return nil, nil, err
		}
		srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, _ = w.Write([]byte("ttyd " + target + " " + r.URL.Path))
		})}
		done := make(chan struct{})
		go func() { _ = srv.Serve(ln); close(done) }()
		t.Cleanup(func() { _ = srv.Close() })
		return func() { _ = srv.Close() }, done, nil
	}
}

func termHarness(t *testing.T, on bool) (*harness, string, string) {
	h := newHarness(t)
	h.srv.cfg.terminal = on
	h.srv.terms = newTermManager(h.srv.cfg)
	h.srv.terms.spawn = fakeTtyd(t)
	t.Cleanup(h.srv.terms.closeAll)
	cookie, csrf := h.login()
	return h, cookie, csrf
}

func TestTerminalIsOffUnlessAskedFor(t *testing.T) {
	h, cookie, csrf := termHarness(t, false)
	if w := h.do(req{path: "/api/me", cookie: cookie}); decode(t, w)["terminal"] != false {
		t.Errorf("/api/me says the terminal is on: %s", w.Body)
	}
	w := h.do(req{method: "POST", path: "/api/term", body: `{"target":"web1:api"}`, cookie: cookie, csrf: csrf})
	if w.Code != 404 {
		t.Errorf("POST /api/term with the terminal off: %d", w.Code)
	}
}

func TestTerminalViewIsProxiedBehindSignIn(t *testing.T) {
	h, cookie, csrf := termHarness(t, true)
	if w := h.do(req{method: "POST", path: "/api/term", body: `{"target":"-x"}`, cookie: cookie, csrf: csrf}); w.Code != 400 {
		t.Errorf("an option as a target: %d", w.Code)
	}
	w := h.do(req{method: "POST", path: "/api/term", body: `{"target":"web1:api@x"}`, cookie: cookie, csrf: csrf})
	var v struct{ URL string }
	if err := json.Unmarshal(w.Body.Bytes(), &v); err != nil || w.Code != 200 || !strings.HasPrefix(v.URL, "/term/") {
		t.Fatalf("start: %d %s", w.Code, w.Body)
	}

	if w := h.do(req{path: v.URL}); w.Code != 401 {
		t.Errorf("the view without a session: %d, want 401", w.Code)
	}
	w = h.do(req{path: v.URL + "token", cookie: cookie})
	if w.Code != 200 || w.Body.String() != "ttyd web1:api@x "+v.URL+"token" {
		t.Errorf("proxied: %d %q", w.Code, w.Body)
	}
	if w := h.do(req{method: "POST", path: v.URL, body: "{}", cookie: cookie, csrf: csrf}); w.Code != 405 {
		t.Errorf("a POST into the view: %d, want 405", w.Code)
	}
	if w := h.do(req{path: "/term/0123456789abcdef0123456789abcdef/", cookie: cookie}); w.Code != 404 {
		t.Errorf("an unknown view: %d", w.Code)
	}
	ws := map[string]string{"Upgrade": "websocket", "Connection": "Upgrade", "Origin": "http://evil.example"}
	if w := h.do(req{path: v.URL + "ws", cookie: cookie, header: ws}); w.Code != 403 {
		t.Errorf("a WebSocket from another origin: %d, want 403", w.Code)
	}
}

func TestAtMostFourTerminalViews(t *testing.T) {
	h, cookie, csrf := termHarness(t, true)
	for i := 0; i < maxTerms; i++ {
		if w := h.do(req{method: "POST", path: "/api/term", body: `{"target":"web1:api"}`, cookie: cookie, csrf: csrf}); w.Code != 200 {
			t.Fatalf("view %d: %d %s", i, w.Code, w.Body)
		}
	}
	if w := h.do(req{method: "POST", path: "/api/term", body: `{"target":"web1:api"}`, cookie: cookie, csrf: csrf}); w.Code != 409 {
		t.Errorf("view %d: %d, want 409", maxTerms+1, w.Code)
	}
}
