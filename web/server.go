package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type server struct {
	cfg     config
	tokens  *tokenStore
	allowed map[string]bool
	limiter loginLimiter
	flight  flightGroup
	now     func() time.Time
}

func newServer(cfg config, tokens *tokenStore) *server {
	return &server{
		cfg:     cfg,
		tokens:  tokens,
		allowed: allowedHosts(cfg.listen, cfg.allowHosts),
		now:     time.Now,
	}
}

// The target grammar, [host:]project[/worktree][@label], with each part held
// to what cx itself accepts (_validate_name, _validate_label, a host alias).
// Every part starts with a letter or digit, so no target can be read as an
// option once it is in cx's argv.
var (
	targetRe = regexp.MustCompile(`^([A-Za-z0-9][A-Za-z0-9._-]*:)?[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9_-]*)?(@[A-Za-z0-9][A-Za-z0-9_-]*)?$`)
	hostRe   = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)
	labelRe  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]*$`)
	cursorRe = regexp.MustCompile(`^([0-9A-Fa-f-]{36}):([0-9]{1,15})$`)
	ansiRe   = regexp.MustCompile(`\x1b\[[0-9;]*[A-Za-z]`)
)

func validTarget(t string) bool { return len(t) <= 200 && targetRe.MatchString(t) }

// maxText is the most a nudge may carry. cx nudge has no limit (the text
// goes over stdin); this one is about what a request body should hold.
const maxText = 32 << 10

func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Frame-Options", "DENY")
	h.Set("Cross-Origin-Opener-Policy", "same-origin")
	h.Set("Cross-Origin-Resource-Policy", "same-origin")
	h.Set("Cache-Control", "no-store")

	if !hostAllowed(s.allowed, r.Host) {
		http.Error(w, "cx web does not answer to this host name; name it with --allow-host", http.StatusMisdirectedRequest)
		return
	}
	// No CORS, so no preflight can succeed: another origin can neither read
	// an answer nor send anything but a simple request, which the CSRF
	// checks then refuse.
	if r.Method == http.MethodOptions {
		http.Error(w, "no cross-origin requests", http.StatusForbidden)
		return
	}

	switch r.URL.Path {
	case "/":
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		s.page(w, r)
	case "/favicon.ico":
		w.WriteHeader(http.StatusNoContent)
	case "/api/login":
		s.login(w, r)
	default:
		if strings.HasPrefix(r.URL.Path, "/api/") {
			s.api(w, r)
			return
		}
		http.NotFound(w, r)
	}
}

// page serves index.html, read from disk each time so that editing it needs
// no rebuild. It holds no data: without a session it can only show the
// sign-in form. Every script and style in it carries a fresh nonce, and the
// CSP allows nothing else, so text that somehow became markup still could
// not run.
func (s *server) page(w http.ResponseWriter, r *http.Request) {
	b, err := os.ReadFile(s.cfg.pagePath)
	if err != nil {
		http.Error(w, "cx web cannot read its page: "+err.Error(), http.StatusInternalServerError)
		return
	}
	nb := make([]byte, 18)
	if _, err := rand.Read(nb); err != nil {
		http.Error(w, "no randomness", http.StatusInternalServerError)
		return
	}
	nonce := base64.StdEncoding.EncodeToString(nb)
	b = bytes.ReplaceAll(b, []byte("{{NONCE}}"), []byte(nonce))
	h := w.Header()
	h.Set("Content-Security-Policy", "default-src 'none'; script-src 'nonce-"+nonce+"'; style-src 'nonce-"+nonce+
		"'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
	h.Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(b)
}

func (s *server) login(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "POST only"})
		return
	}
	if !sameOrigin(r) {
		writeJSON(w, http.StatusForbidden, map[string]any{"error": "cross-origin request refused"})
		return
	}
	now := s.now()
	addr := remoteAddr(r)
	if s.limiter.blocked(addr, now) {
		writeJSON(w, http.StatusTooManyRequests, map[string]any{"error": "too many wrong tokens; wait a minute"})
		return
	}
	var body struct {
		Token string `json:"token"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	if !s.tokens.matches(strings.TrimSpace(body.Token)) {
		s.limiter.fail(addr, now)
		fmt.Fprintf(os.Stderr, "cx web: a wrong token from %s\n", addr)
		time.Sleep(300 * time.Millisecond)
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "that is not the token"})
		return
	}
	cookie, csrf := s.tokens.newSession(now)
	http.SetCookie(w, &http.Cookie{
		Name:     cookieName,
		Value:    cookie,
		Path:     "/",
		MaxAge:   int(sessionTTL / time.Second),
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
		Secure:   secure(r),
	})
	writeJSON(w, http.StatusOK, s.me(csrf))
}

// secure says whether the browser reached this over HTTPS: directly, or
// through a proxy that says so. A forged header only adds Secure to a
// cookie, which cannot make anything less safe.
func secure(r *http.Request) bool {
	return r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https")
}

func (s *server) me(csrf string) map[string]any {
	return map[string]any{"csrf": csrf, "interval": s.cfg.interval, "version": s.cfg.version}
}

// api authenticates, then routes. A bearer token is for scripts: it is never
// sent by a browser on its own, so it needs no CSRF check. A cookie is, so
// every POST made with one must also come from this origin and carry the
// CSRF token, which only a page that signed in could have read.
func (s *server) api(w http.ResponseWriter, r *http.Request) {
	csrf := ""
	if b := bearer(r); b != "" {
		if !s.tokens.matches(b) {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "sign in"})
			return
		}
	} else {
		c, err := r.Cookie(cookieName)
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "sign in"})
			return
		}
		issued, ok := s.tokens.session(c.Value, s.now())
		if !ok {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "sign in"})
			return
		}
		csrf = s.tokens.mac("csrf", issued)
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			if !sameOrigin(r) {
				writeJSON(w, http.StatusForbidden, map[string]any{"error": "cross-origin request refused"})
				return
			}
			if !hmac.Equal([]byte(r.Header.Get("X-CX-CSRF")), []byte(csrf)) {
				writeJSON(w, http.StatusForbidden, map[string]any{"error": "missing or stale CSRF token; reload the page"})
				return
			}
		}
	}

	type route struct {
		method string
		fn     func(http.ResponseWriter, *http.Request)
	}
	routes := map[string]route{
		"/api/me":       {http.MethodGet, func(w http.ResponseWriter, _ *http.Request) { writeJSON(w, http.StatusOK, s.me(csrf)) }},
		"/api/logout":   {http.MethodPost, s.logout},
		"/api/sessions": {http.MethodGet, s.sessions},
		"/api/goals":    {http.MethodGet, s.goals},
		"/api/tail":     {http.MethodGet, s.tail},
		"/api/nudge":    {http.MethodPost, s.nudge},
		"/api/open":     {http.MethodPost, s.open},
		"/api/stop":     {http.MethodPost, s.stop},
		"/api/goal":     {http.MethodPost, s.goal},
	}
	rt, ok := routes[r.URL.Path]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "no such route"})
		return
	}
	if r.Method != rt.method {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": rt.method + " only"})
		return
	}
	rt.fn(w, r)
}

func (s *server) logout(w http.ResponseWriter, r *http.Request) {
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: "", Path: "/", MaxAge: -1,
		HttpOnly: true, SameSite: http.SameSiteStrictMode, Secure: secure(r)})
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// ---------------------------------------------------------------------------
// Running cx
// ---------------------------------------------------------------------------

type cxResult struct {
	code   int
	out    []byte
	stderr string
}

// cx runs the CLI by argv, never through a shell (invariant 1), with stdin
// as given and never a terminal, so it cannot stop to ask anything. stdout
// is the answer; stderr is kept apart and is only ever shown (invariant 2).
// The whole process group is killed on timeout, because cx's children are
// ssh processes that would otherwise outlive it.
func (s *server) cx(ctx context.Context, stdin string, timeout time.Duration, args ...string) cxResult {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, s.cfg.cxPath, append([]string{"--no-color"}, args...)...)
	cmd.Stdin = strings.NewReader(stdin)
	cmd.Env = append(os.Environ(), "CX_PICKER=none", "NO_COLOR=1")
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 2 * time.Second

	err := cmd.Run()
	res := cxResult{out: out.Bytes(), stderr: cleanStderr(errb.String())}
	var ee *exec.ExitError
	switch {
	case err == nil:
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		res.code = 124
		res.stderr = strings.TrimSpace(res.stderr + "\ncx did not answer within " + timeout.String())
	case errors.As(err, &ee):
		res.code = ee.ExitCode()
		if res.code < 0 {
			res.code = 1
		}
	default:
		res.code = 127
		res.stderr = "cannot run cx: " + err.Error()
	}
	return res
}

func cleanStderr(s string) string {
	s = strings.TrimSpace(ansiRe.ReplaceAllString(s, ""))
	if len(s) > 4000 {
		s = "…" + s[len(s)-4000:]
	}
	return s
}

// statusFor maps cx's exit codes (stable, documented in CLAUDE.md) to HTTP.
func statusFor(code int) int {
	switch code {
	case 0:
		return http.StatusOK
	case 2:
		return http.StatusNotFound
	case 3, 130:
		return http.StatusBadRequest
	case 4, 5:
		return http.StatusConflict
	case 124:
		return http.StatusGatewayTimeout
	default:
		return http.StatusBadGateway
	}
}

// reply answers with what cx printed. On success that is cx's own JSON,
// untouched; on failure the same, plus what it said on stderr and its exit
// code, so the page can show the CLI's words rather than inventing its own.
func reply(w http.ResponseWriter, res cxResult) {
	body := map[string]any{}
	if t := bytes.TrimSpace(res.out); len(t) > 0 {
		if err := json.Unmarshal(t, &body); err != nil {
			body = map[string]any{"output": string(t)}
		}
	}
	if res.code != 0 {
		msg := res.stderr
		if msg == "" {
			msg = "cx exited " + strconv.Itoa(res.code)
		}
		body["error"] = msg
		body["exit"] = res.code
	}
	writeJSON(w, statusFor(res.code), body)
}

// flightGroup shares one run between identical requests in flight: two
// pages asking for the board at once get one cx peek. It is not a cache —
// nothing outlives the call (invariant 4).
type flightGroup struct {
	mu    sync.Mutex
	calls map[string]*flightCall
}

type flightCall struct {
	wg     sync.WaitGroup
	status int
	body   []byte
}

func (g *flightGroup) do(key string, fn func() (int, []byte)) (int, []byte) {
	g.mu.Lock()
	if g.calls == nil {
		g.calls = map[string]*flightCall{}
	}
	if c, ok := g.calls[key]; ok {
		g.mu.Unlock()
		c.wg.Wait()
		return c.status, c.body
	}
	c := &flightCall{}
	c.wg.Add(1)
	g.calls[key] = c
	g.mu.Unlock()

	c.status, c.body = fn()
	c.wg.Done()
	g.mu.Lock()
	delete(g.calls, key)
	g.mu.Unlock()
	return c.status, c.body
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

// sessions is the board: cx peek for state, and the cached cx ls for each
// project's branch and which servers answered. The page joins the two; the
// server passes both through as cx printed them.
func (s *server) sessions(w http.ResponseWriter, _ *http.Request) {
	status, body := s.flight.do("sessions", func() (int, []byte) {
		ctx := context.Background()
		var peek, ls cxResult
		var wg sync.WaitGroup
		wg.Add(2)
		go func() { defer wg.Done(); peek = s.cx(ctx, "", 90*time.Second, "--json", "peek", "--tail", "0") }()
		go func() { defer wg.Done(); ls = s.cx(ctx, "", 90*time.Second, "--json", "ls") }()
		wg.Wait()
		if peek.code != 0 {
			return encode(statusFor(peek.code), map[string]any{"error": orExit(peek), "exit": peek.code})
		}
		out := map[string]any{"peek": json.RawMessage(bytes.TrimSpace(peek.out)), "ls": nil, "warnings": []string{}}
		if ls.code == 0 && json.Valid(bytes.TrimSpace(ls.out)) {
			out["ls"] = json.RawMessage(bytes.TrimSpace(ls.out))
		}
		var warn []string
		for _, e := range []string{peek.stderr, ls.stderr} {
			if e != "" {
				warn = append(warn, e)
			}
		}
		if warn != nil {
			out["warnings"] = warn
		}
		return encode(http.StatusOK, out)
	})
	writeRaw(w, status, body)
}

// goals is every goal on every configured server. A goal lives on exactly
// one host, so this is one cx goal ls per host, in parallel. The page shows
// a goal's last twenty log entries and not its revisions, so the rest is
// left out here rather than sent to a phone.
func (s *server) goals(w http.ResponseWriter, _ *http.Request) {
	status, body := s.flight.do("goals", func() (int, []byte) {
		ctx := context.Background()
		hl := s.cx(ctx, "", 60*time.Second, "--json", "host", "ls")
		if hl.code != 0 {
			return encode(statusFor(hl.code), map[string]any{"error": orExit(hl), "exit": hl.code})
		}
		var hosts []struct {
			Alias string `json:"alias"`
		}
		if err := json.Unmarshal(hl.out, &hosts); err != nil {
			return encode(http.StatusBadGateway, map[string]any{"error": "cx host ls: " + err.Error()})
		}
		type hostGoals struct {
			goals []map[string]any
			err   string
		}
		res := make([]hostGoals, len(hosts))
		var wg sync.WaitGroup
		for i, h := range hosts {
			if !hostRe.MatchString(h.Alias) {
				continue
			}
			wg.Add(1)
			go func(i int, host string) {
				defer wg.Done()
				r := s.cx(ctx, "", 60*time.Second, "--json", "goal", "--host", host, "ls")
				if r.code != 0 {
					res[i].err = orExit(r)
					return
				}
				var v struct {
					Goals []map[string]any `json:"goals"`
				}
				if err := json.Unmarshal(r.out, &v); err != nil {
					res[i].err = err.Error()
					return
				}
				for _, g := range v.Goals {
					g["host"] = host
					delete(g, "revisions")
					if log, ok := g["log"].([]any); ok && len(log) > 20 {
						g["log"] = log[len(log)-20:]
					}
				}
				res[i].goals = v.Goals
			}(i, h.Alias)
		}
		wg.Wait()
		goals := []map[string]any{}
		errs := []map[string]string{}
		for i, r := range res {
			goals = append(goals, r.goals...)
			if r.err != "" {
				errs = append(errs, map[string]string{"host": hosts[i].Alias, "error": r.err})
			}
		}
		return encode(http.StatusOK, map[string]any{"goals": goals, "errors": errs})
	})
	writeRaw(w, status, body)
}

// tail is the live view, as Server-Sent Events. Each connection is exactly
// one cx tail and then closes; EventSource reconnects by itself after
// `retry` and hands back the `id` it last saw — "uuid:offset" — as
// Last-Event-ID. So the cursor lives in the browser, the loop is the
// browser's, and no request here outlives one read (invariant 11).
func (s *server) tail(w http.ResponseWriter, r *http.Request) {
	target := r.URL.Query().Get("target")
	if !validTarget(target) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "not a target"})
		return
	}
	args := []string{"--json", "tail", target}
	if m := cursorRe.FindStringSubmatch(r.Header.Get("Last-Event-ID")); m != nil {
		args = append(args, "--from", m[2], "--uuid", m[1])
	}
	res := s.cx(r.Context(), "", 60*time.Second, args...)

	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)

	if res.code != 0 {
		// Sent as an event, not an HTTP error: an error status ends an
		// EventSource for good, and an unreachable server is usually a
		// passing thing. The page closes the stream itself when the event
		// says retrying will not help.
		permanent := res.code == 2 || res.code == 3
		data, _ := json.Marshal(map[string]any{"error": orExit(res), "exit": res.code, "permanent": permanent})
		fmt.Fprintf(w, "retry: 10000\nevent: failure\ndata: %s\n\n", data)
		return
	}
	var v struct {
		UUID     *string           `json:"uuid"`
		Offset   int64             `json:"offset"`
		Reset    bool              `json:"reset"`
		Messages []json.RawMessage `json:"messages"`
	}
	var compact bytes.Buffer
	if err := json.Unmarshal(res.out, &v); err != nil || json.Compact(&compact, res.out) != nil {
		fmt.Fprintf(w, "retry: 10000\nevent: failure\ndata: {\"error\":\"cx tail printed something that is not JSON\"}\n\n")
		return
	}
	// Ask again soon after something arrived, more slowly while nothing does.
	retry := 3000
	if len(v.Messages) > 0 {
		retry = 1000
	}
	fmt.Fprintf(w, "retry: %d\n", retry)
	if v.UUID != nil {
		fmt.Fprintf(w, "id: %s:%d\n", *v.UUID, v.Offset)
	}
	if len(v.Messages) > 0 || v.Reset {
		fmt.Fprintf(w, "event: tail\ndata: %s\n\n", compact.Bytes())
	} else {
		// A block with no data still moves Last-Event-ID on.
		fmt.Fprint(w, "\n")
	}
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

// An action runs to the end even if the page goes away mid-request: a nudge
// cut off halfway is worse than one whose answer nobody read.
func detached(r *http.Request) context.Context { return context.WithoutCancel(r.Context()) }

func needConfirm(w http.ResponseWriter, what, why string) {
	writeJSON(w, http.StatusPreconditionRequired, map[string]any{"error": why, "need_confirm": what})
}

// nudge is cx nudge, with the text on stdin. Two things need the target
// typed back, and the server checks both itself rather than trusting the
// page: a session with no permission checks, where the text runs as code,
// and --force, which overrides cx's own refusal.
func (s *server) nudge(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Target  string `json:"target"`
		Text    string `json:"text"`
		Force   bool   `json:"force"`
		Confirm string `json:"confirm"`
	}
	if !readJSON(w, r, &b) {
		return
	}
	if !validTarget(b.Target) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "not a target"})
		return
	}
	if strings.TrimSpace(b.Text) == "" || len(b.Text) > maxText {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "the message is empty or longer than 32 KB"})
		return
	}
	ctx := detached(r)
	look := s.cx(ctx, "", 60*time.Second, "--json", "peek", b.Target, "--tail", "0")
	if look.code != 0 {
		reply(w, look)
		return
	}
	var p struct {
		Sessions []struct {
			PermMode  *string `json:"perm_mode"`
			Dangerous bool    `json:"dangerous"`
		} `json:"sessions"`
	}
	_ = json.Unmarshal(look.out, &p)
	noPerms := false
	for _, x := range p.Sessions {
		if x.Dangerous || (x.PermMode != nil && *x.PermMode == "bypassPermissions") {
			noPerms = true
		}
	}
	if (noPerms || b.Force) && b.Confirm != b.Target {
		why := "--force overrides cx's own refusal; type the target to confirm"
		what := "force"
		if noPerms {
			why = "this session runs with no permission checks, so a message to it runs as code on that server; type the target to confirm"
			what = "no-perms"
		}
		needConfirm(w, what, why)
		return
	}
	args := []string{"--json", "nudge", b.Target}
	if b.Force {
		args = append(args, "--force")
	}
	res := s.cx(ctx, b.Text, 60*time.Second, args...)
	logAction("nudge", b.Target, res, fmt.Sprintf("force=%v no-perms=%v", b.Force, noPerms))
	reply(w, res)
}

func (s *server) open(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Target        string `json:"target"`
		RemoteControl *bool  `json:"remote_control"`
	}
	if !readJSON(w, r, &b) {
		return
	}
	if !validTarget(b.Target) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "not a target"})
		return
	}
	args := []string{"--json", "open", "-d", b.Target}
	if b.RemoteControl != nil {
		if *b.RemoteControl {
			args = append(args, "--remote-control")
		} else {
			args = append(args, "--no-remote-control")
		}
	}
	res := s.cx(detached(r), "", 120*time.Second, args...)
	logAction("open", b.Target, res, "")
	reply(w, res)
}

func (s *server) stop(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Target  string `json:"target"`
		Confirm string `json:"confirm"`
	}
	if !readJSON(w, r, &b) {
		return
	}
	if !validTarget(b.Target) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "not a target"})
		return
	}
	if b.Confirm != b.Target {
		needConfirm(w, "stop", "stopping ends the Claude process; type the target to confirm")
		return
	}
	res := s.cx(detached(r), "", 60*time.Second, "--json", "-y", "stop", b.Target)
	logAction("stop", b.Target, res, "")
	reply(w, res)
}

func (s *server) goal(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Host    string `json:"host"`
		Name    string `json:"name"`
		Action  string `json:"action"`
		Confirm string `json:"confirm"`
	}
	if !readJSON(w, r, &b) {
		return
	}
	if !hostRe.MatchString(b.Host) || !labelRe.MatchString(b.Name) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "not a goal"})
		return
	}
	switch b.Action {
	case "pause", "resume":
	case "done":
		if b.Confirm != b.Name {
			needConfirm(w, "done", "marking a goal done ends its driving; type the goal's name to confirm")
			return
		}
	default:
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "action is pause, resume or done"})
		return
	}
	res := s.cx(detached(r), "", 60*time.Second, "--json", "goal", "--host", b.Host, b.Action, b.Name)
	logAction("goal "+b.Action, b.Host+":"+b.Name, res, "")
	reply(w, res)
}

// logAction leaves a line on stderr for everything that changed something,
// so whoever runs cx web can see what was done through it. Never the text
// of a nudge: that is the user's, and may hold anything.
func logAction(what, target string, res cxResult, extra string) {
	line := fmt.Sprintf("cx web: %s %s -> exit %d", what, target, res.code)
	if extra != "" {
		line += " (" + extra + ")"
	}
	fmt.Fprintln(os.Stderr, line)
}

// ---------------------------------------------------------------------------
// JSON
// ---------------------------------------------------------------------------

// readJSON takes only application/json, which a cross-origin form cannot
// send without a preflight, and only a small body.
func readJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	ct := r.Header.Get("Content-Type")
	if !strings.HasPrefix(strings.ToLower(strings.TrimSpace(ct)), "application/json") {
		writeJSON(w, http.StatusUnsupportedMediaType, map[string]any{"error": "send application/json"})
		return false
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad request body: " + err.Error()})
		return false
	}
	return true
}

func orExit(r cxResult) string {
	if r.stderr != "" {
		return r.stderr
	}
	return "cx exited " + strconv.Itoa(r.code)
}

func encode(status int, v any) (int, []byte) {
	b, err := json.Marshal(v)
	if err != nil {
		return http.StatusInternalServerError, []byte(`{"error":"cannot encode the answer"}`)
	}
	return status, b
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	s, b := encode(status, v)
	writeRaw(w, s, b)
}

func writeRaw(w http.ResponseWriter, status int, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
	_, _ = w.Write([]byte("\n"))
}
