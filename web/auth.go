package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// cookieName is the session cookie. Not __Host-: that prefix needs Secure,
// and the default is plain http on 127.0.0.1.
const cookieName = "cx_web"

// sessionTTL is how long a sign-in lasts. Rotating the token ends every one
// at once, whatever its age.
const sessionTTL = 30 * 24 * time.Hour

// tokenStore is the one secret: 32 random bytes as hex, in a 0600 file.
//
// It is re-read whenever the file changes, so `cx web --rotate-token` from
// another terminal takes effect on a running server without a restart: the
// old token stops working, and so does every cookie, since a cookie is an
// HMAC keyed by the token.
type tokenStore struct {
	path string

	mu   sync.Mutex
	tok  string
	mod  time.Time
	size int64
}

func newTokenStore(path string) (*tokenStore, error) {
	t := &tokenStore{path: path}
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		if err := t.write(); err != nil {
			return nil, err
		}
	}
	if err := t.load(); err != nil {
		return nil, err
	}
	return t, nil
}

// load reads the file, and refuses one anyone else can read: it is the key
// to every session cx can reach. A mode that drifted is put back, loudly,
// rather than refused, because the remedy is the same either way.
func (t *tokenStore) load() error {
	fi, err := os.Stat(t.path)
	if err != nil {
		return fmt.Errorf("cannot read the token: %v", err)
	}
	if fi.Mode().Perm()&0o077 != 0 {
		fmt.Fprintf(os.Stderr, "cx web: %s was readable by others (%v); setting it to 0600.\n", t.path, fi.Mode().Perm())
		fmt.Fprintln(os.Stderr, "        Anyone who read it could sign in: cx web --rotate-token replaces it.")
		if err := os.Chmod(t.path, 0o600); err != nil {
			return fmt.Errorf("cannot make %s private: %v", t.path, err)
		}
	}
	b, err := os.ReadFile(t.path)
	if err != nil {
		return fmt.Errorf("cannot read the token: %v", err)
	}
	tok := strings.TrimSpace(string(b))
	if len(tok) < 32 || strings.ContainsAny(tok, " \t\r\n") {
		return fmt.Errorf("%s does not hold a token; replace it with: cx web --rotate-token", t.path)
	}
	t.mu.Lock()
	t.tok, t.mod, t.size = tok, fi.ModTime(), fi.Size()
	t.mu.Unlock()
	return nil
}

// write makes a new token: a temporary file created 0600 in the same
// directory, then renamed over the old one, so no reader ever sees half a
// token and the file is never briefly readable by others.
func (t *tokenStore) write() error {
	dir := filepath.Dir(t.path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("cannot create %s: %v", dir, err)
	}
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return fmt.Errorf("no randomness for a token: %v", err)
	}
	f, err := os.CreateTemp(dir, ".web.token.*")
	if err != nil {
		return fmt.Errorf("cannot write the token: %v", err)
	}
	defer os.Remove(f.Name())
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		return err
	}
	if _, err := f.WriteString(hex.EncodeToString(b) + "\n"); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), t.path)
}

func (t *tokenStore) rotate() error {
	if err := t.write(); err != nil {
		return err
	}
	return t.load()
}

// current is the token as the file says now.
func (t *tokenStore) current() string {
	if fi, err := os.Stat(t.path); err == nil {
		t.mu.Lock()
		changed := !fi.ModTime().Equal(t.mod) || fi.Size() != t.size
		t.mu.Unlock()
		if changed {
			if err := t.load(); err != nil {
				fmt.Fprintln(os.Stderr, "cx web: "+err.Error())
				// A token that can no longer be read signs nobody in.
				t.mu.Lock()
				t.tok = ""
				t.mu.Unlock()
			}
		}
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.tok
}

func (t *tokenStore) matches(candidate string) bool {
	tok := t.current()
	if tok == "" || candidate == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(tok), []byte(candidate)) == 1
}

func (t *tokenStore) mac(purpose, issued string) string {
	m := hmac.New(sha256.New, []byte(t.current()))
	m.Write([]byte(purpose + "|" + issued))
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

// A session cookie is "<issued unix time>.<HMAC(token, session|issued)>",
// and its CSRF token is HMAC(token, csrf|issued). Nothing is stored: the
// server can check both from the token alone, which is what lets it keep no
// state (and what makes rotating the token end every session).
func (t *tokenStore) newSession(now time.Time) (cookie, csrf string) {
	issued := strconv.FormatInt(now.Unix(), 10)
	return issued + "." + t.mac("session", issued), t.mac("csrf", issued)
}

// session checks a cookie value and returns its issue time.
func (t *tokenStore) session(value string, now time.Time) (string, bool) {
	issued, sig, ok := strings.Cut(value, ".")
	if !ok {
		return "", false
	}
	n, err := strconv.ParseInt(issued, 10, 64)
	if err != nil {
		return "", false
	}
	at := time.Unix(n, 0)
	if at.After(now.Add(time.Minute)) || now.Sub(at) > sessionTTL {
		return "", false
	}
	if t.current() == "" || !hmac.Equal([]byte(sig), []byte(t.mac("session", issued))) {
		return "", false
	}
	return issued, true
}

// loginLimiter slows down guessing, per address. A 256-bit token cannot be
// guessed, but a page reachable from a phone is reachable from elsewhere
// too, and a flood of attempts should be cheap to turn away. Behind a
// reverse proxy every attempt comes from the proxy, so there it is one
// budget for everyone, which is the safe direction to be wrong in.
type loginLimiter struct {
	mu    sync.Mutex
	fails map[string]*loginWindow
}

type loginWindow struct {
	start time.Time
	n     int
}

const maxLoginFailures = 10

func (l *loginLimiter) window(addr string, now time.Time) *loginWindow {
	if l.fails == nil {
		l.fails = map[string]*loginWindow{}
	}
	for k, w := range l.fails {
		if now.Sub(w.start) > time.Minute {
			delete(l.fails, k)
		}
	}
	w := l.fails[addr]
	if w == nil {
		w = &loginWindow{start: now}
		l.fails[addr] = w
	}
	return w
}

func (l *loginLimiter) blocked(addr string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.window(addr, now).n >= maxLoginFailures
}

func (l *loginLimiter) fail(addr string, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.window(addr, now).n++
}

func remoteAddr(r *http.Request) string {
	if h, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return h
	}
	return r.RemoteAddr
}

// hostAllowed answers DNS rebinding: a page on another site can point a name
// it controls at 127.0.0.1, and the browser then treats this server as that
// site's origin. Answering only to names that mean this machine (and to the
// ones --allow-host adds, for a reverse proxy) closes that.
func hostAllowed(allowed map[string]bool, hostHeader string) bool {
	h := hostHeader
	if host, _, err := net.SplitHostPort(hostHeader); err == nil {
		h = host
	}
	h = strings.ToLower(strings.TrimSuffix(strings.TrimPrefix(h, "["), "]"))
	return h != "" && allowed[h]
}

func allowedHosts(listen string, extra []string) map[string]bool {
	m := map[string]bool{"127.0.0.1": true, "localhost": true, "::1": true}
	host, _, _ := net.SplitHostPort(listen)
	host = strings.ToLower(host)
	switch host {
	case "", "0.0.0.0", "::":
		// Listening everywhere: every address this machine has is a name for
		// it. An IP literal cannot be rebound, so these are safe to add.
		if addrs, err := net.InterfaceAddrs(); err == nil {
			for _, a := range addrs {
				if ipn, ok := a.(*net.IPNet); ok {
					m[ipn.IP.String()] = true
				}
			}
		}
	default:
		m[host] = true
	}
	for _, e := range extra {
		e = strings.ToLower(strings.TrimSpace(e))
		if h, _, err := net.SplitHostPort(e); err == nil {
			e = h
		}
		if e != "" {
			m[e] = true
		}
	}
	return m
}

// sameOrigin is the CSRF check that does not depend on the token: a POST
// from a browser carries Origin, and it must name this server. SameSite=
// Strict and the X-CX-CSRF header are the other two layers.
func sameOrigin(r *http.Request) bool {
	if site := r.Header.Get("Sec-Fetch-Site"); site != "" && site != "same-origin" {
		return false
	}
	o := r.Header.Get("Origin")
	if o == "" || o == "null" {
		return false
	}
	u, err := url.Parse(o)
	if err != nil {
		return false
	}
	return strings.EqualFold(u.Host, r.Host)
}

func bearer(r *http.Request) string {
	a := r.Header.Get("Authorization")
	if len(a) > 7 && strings.EqualFold(a[:7], "bearer ") {
		return strings.TrimSpace(a[7:])
	}
	return ""
}
