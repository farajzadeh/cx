package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeCx stands in for the cx CLI: it records its argv (one per line) and
// its stdin, and answers each verb the way the real one does, in shape.
const fakeCx = `#!/bin/sh
d="$FAKE_DIR"
printf '%s\n' "$@" >"$d/argv"
cat >"$d/stdin"
shift # --no-color
[ "$1" = --json ] && shift
[ "$1" = -y ] && shift
case "$1" in
  peek)
    case "$2" in
      *missing*) echo "cx: no such project" >&2; exit 2 ;;
      *noperms*) echo '{"sessions":[{"target":"x","perm_mode":"bypassPermissions"}]}' ;;
      --tail) echo '{"idle_grace":30,"sessions":[{"host":"web1","target":"api","state":"idle"}]}'; echo "warning: web2 unreachable" >&2 ;;
      *) echo '{"sessions":[{"target":"x","perm_mode":null}]}' ;;
    esac ;;
  ls) echo '{"projects":[{"host":"web1","name":"api","branch":"main"}],"servers":[{"host":"web1","ok":true}]}' ;;
  nudge) echo '{"target":"web1:api","sent":true,"reason":null}' ;;
  tail)
    case "$2" in *missing*) echo "cx: no such project" >&2; exit 2 ;; esac
    if [ "$3" = --from ]; then
      echo '{"host":"web1","target":"api","uuid":"'"$6"'","offset":'"$4"',"size":'"$4"',"reset":false,"messages":[]}'
    else
      echo '{"host":"web1","target":"api","uuid":"11111111-2222-3333-4444-555555555555","offset":42,"size":42,"reset":true,
"messages":[{"role":"user","text":"<b>hi</b>"}]}'
    fi ;;
  host) echo '[{"alias":"web1"},{"alias":"web2"}]' ;;
  goal)
    if [ "$3" = web2 ]; then echo "cx: cannot reach web2" >&2; exit 1; fi
    case "$4" in
      ls)
        log=""; i=0
        while [ $i -lt 25 ]; do log="$log{\"n\":$i},"; i=$((i+1)); done
        echo '{"goals":[{"name":"g","state":"active","members":["api"],"revisions":[{"x":1}],"log":['"${log%,}"']}],"host":"web1"}' ;;
      *) echo '{"name":"'"$5"'","state":"paused","host":"web1"}' ;;
    esac ;;
  stop) echo '{"stopped":true}' ;;
  open) echo '{"started":true}' ;;
  *) echo "cx: unknown $1" >&2; exit 3 ;;
esac
`

type harness struct {
	t   *testing.T
	dir string
	srv *server
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	dir := t.TempDir()
	cx := filepath.Join(dir, "cx")
	if err := os.WriteFile(cx, []byte(fakeCx), 0o755); err != nil {
		t.Fatal(err)
	}
	page := filepath.Join(dir, "index.html")
	if err := os.WriteFile(page, []byte(`<script nonce="{{NONCE}}">x</script>`), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FAKE_DIR", dir)
	tokens, err := newTokenStore(filepath.Join(dir, "config", "web.token"))
	if err != nil {
		t.Fatal(err)
	}
	cfg := config{listen: "127.0.0.1:8377", cxPath: cx, pagePath: page, interval: 10, version: "test"}
	return &harness{t: t, dir: dir, srv: newServer(cfg, tokens)}
}

type req struct {
	method, path, body string
	host, origin       string
	cookie, csrf, auth string
	ctype              string
	header             map[string]string
}

func (h *harness) do(q req) *httptest.ResponseRecorder {
	h.t.Helper()
	if q.method == "" {
		q.method = http.MethodGet
	}
	r := httptest.NewRequest(q.method, q.path, strings.NewReader(q.body))
	r.Host = "127.0.0.1:8377"
	if q.host != "" {
		r.Host = q.host
	}
	if q.method == http.MethodPost {
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Origin", "http://127.0.0.1:8377")
	}
	if q.ctype != "" {
		r.Header.Set("Content-Type", q.ctype)
	}
	if q.origin != "" {
		r.Header.Set("Origin", q.origin)
	}
	if q.cookie != "" {
		r.AddCookie(&http.Cookie{Name: cookieName, Value: q.cookie})
	}
	if q.csrf != "" {
		r.Header.Set("X-CX-CSRF", q.csrf)
	}
	if q.auth != "" {
		r.Header.Set("Authorization", "Bearer "+q.auth)
	}
	for k, v := range q.header {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	h.srv.ServeHTTP(w, r)
	return w
}

// login signs in the way the page does and returns the cookie and CSRF token.
func (h *harness) login() (string, string) {
	h.t.Helper()
	w := h.do(req{method: "POST", path: "/api/login", body: `{"token":"` + h.srv.tokens.current() + `"}`})
	if w.Code != 200 {
		h.t.Fatalf("login: %d %s", w.Code, w.Body)
	}
	var cookie string
	for _, c := range w.Result().Cookies() {
		if c.Name == cookieName {
			cookie = c.Value
			if !c.HttpOnly || c.SameSite != http.SameSiteStrictMode {
				h.t.Errorf("cookie must be HttpOnly and SameSite=Strict: %+v", c)
			}
		}
	}
	var me struct{ CSRF string }
	_ = json.Unmarshal(w.Body.Bytes(), &me)
	if cookie == "" || me.CSRF == "" {
		h.t.Fatalf("login gave no cookie or no csrf: %s", w.Body)
	}
	return cookie, me.CSRF
}

func (h *harness) file(name string) string {
	b, _ := os.ReadFile(filepath.Join(h.dir, name))
	return string(b)
}

func decode(t *testing.T, w *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	m := map[string]any{}
	if err := json.Unmarshal(w.Body.Bytes(), &m); err != nil {
		t.Fatalf("not JSON: %s", w.Body)
	}
	return m
}

func TestTokenFileIsPrivateAndRotates(t *testing.T) {
	h := newHarness(t)
	path := filepath.Join(h.dir, "config", "web.token")
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Errorf("token file mode %v, want 0600", fi.Mode().Perm())
	}
	if d, _ := os.Stat(filepath.Dir(path)); d.Mode().Perm() != 0o700 {
		t.Errorf("token directory mode %v, want 0700", d.Mode().Perm())
	}
	if n := len(h.srv.tokens.current()); n != 64 {
		t.Errorf("token is %d characters, want 64", n)
	}

	cookie, _ := h.login()
	old := h.srv.tokens.current()
	// Rotated by another process, as cx web --rotate-token does: the running
	// server must notice the file, not be told.
	other, err := newTokenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(10 * time.Millisecond)
	if err := other.rotate(); err != nil {
		t.Fatal(err)
	}
	if h.srv.tokens.current() == old {
		t.Fatal("the server kept the old token after rotation")
	}
	if w := h.do(req{path: "/api/me", cookie: cookie}); w.Code != 401 {
		t.Errorf("a cookie from before rotation still works: %d", w.Code)
	}
	if w := h.do(req{path: "/api/me", auth: old}); w.Code != 401 {
		t.Errorf("the old token still works: %d", w.Code)
	}
}

func TestTokenFileReadableByOthersIsMadePrivate(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "web.token")
	if err := os.WriteFile(path, []byte(strings.Repeat("ab", 32)+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := newTokenStore(path); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Stat(path); fi.Mode().Perm() != 0o600 {
		t.Errorf("mode %v, want 0600", fi.Mode().Perm())
	}
	if err := os.WriteFile(path, []byte("short\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := newTokenStore(path); err == nil {
		t.Error("a file holding no token was accepted")
	}
}

func TestEveryAPIRouteNeedsAuth(t *testing.T) {
	h := newHarness(t)
	for _, p := range []string{"/api/me", "/api/sessions", "/api/goals", "/api/tail?target=web1:api"} {
		if w := h.do(req{path: p}); w.Code != 401 {
			t.Errorf("GET %s without a session: %d, want 401", p, w.Code)
		}
	}
	for _, p := range []string{"/api/nudge", "/api/open", "/api/stop", "/api/goal", "/api/logout"} {
		if w := h.do(req{method: "POST", path: p, body: `{}`}); w.Code != 401 {
			t.Errorf("POST %s without a session: %d, want 401", p, w.Code)
		}
	}
	if w := h.do(req{path: "/api/me", cookie: "123.forged"}); w.Code != 401 {
		t.Errorf("a forged cookie: %d", w.Code)
	}
	if _, err := os.Stat(filepath.Join(h.dir, "argv")); err == nil {
		t.Error("cx ran for a request that was not signed in")
	}
}

func TestThePageIsServedWithANonceAndNoData(t *testing.T) {
	h := newHarness(t)
	w := h.do(req{path: "/"})
	if w.Code != 200 {
		t.Fatalf("GET /: %d", w.Code)
	}
	csp := w.Header().Get("Content-Security-Policy")
	body := w.Body.String()
	if strings.Contains(body, "{{NONCE}}") {
		t.Error("the nonce placeholder was left in the page")
	}
	i := strings.Index(csp, "'nonce-")
	if i < 0 {
		t.Fatalf("no nonce in the CSP: %s", csp)
	}
	nonce := csp[i+7 : i+7+strings.Index(csp[i+7:], "'")]
	if !strings.Contains(body, `nonce="`+nonce+`"`) {
		t.Errorf("the page's nonce does not match the CSP's")
	}
	for _, want := range []string{"default-src 'none'", "frame-ancestors 'none'", "connect-src 'self'"} {
		if !strings.Contains(csp, want) {
			t.Errorf("CSP lacks %q: %s", want, csp)
		}
	}
	if w.Header().Get("X-Frame-Options") != "DENY" {
		t.Error("no X-Frame-Options: DENY")
	}
	if w2 := h.do(req{path: "/"}); strings.Contains(w2.Header().Get("Content-Security-Policy"), nonce) {
		t.Error("the nonce did not change between requests")
	}
}

func TestOnlyThisMachinesNamesAreAnswered(t *testing.T) {
	h := newHarness(t)
	if hostAllowed(h.srv.allowed, "") {
		t.Error("an empty Host was allowed")
	}
	for _, host := range []string{"evil.example:8377", "attacker.test", "127.0.0.1.evil.example"} {
		if w := h.do(req{path: "/", host: host}); w.Code != http.StatusMisdirectedRequest {
			t.Errorf("Host %q: %d, want 421 (DNS rebinding)", host, w.Code)
		}
	}
	for _, host := range []string{"127.0.0.1:8377", "localhost:8377", "[::1]:8377"} {
		if w := h.do(req{path: "/", host: host}); w.Code != 200 {
			t.Errorf("Host %q: %d, want 200", host, w.Code)
		}
	}
	h.srv.allowed = allowedHosts("127.0.0.1:8377", []string{"board.example.com"})
	if w := h.do(req{path: "/", host: "board.example.com"}); w.Code != 200 {
		t.Errorf("--allow-host name refused: %d", w.Code)
	}
}

func TestLogin(t *testing.T) {
	h := newHarness(t)
	if w := h.do(req{method: "POST", path: "/api/login", body: `{"token":"nope"}`}); w.Code != 401 {
		t.Errorf("a wrong token: %d", w.Code)
	}
	good := `{"token":"` + h.srv.tokens.current() + `"}`
	if w := h.do(req{method: "POST", path: "/api/login", body: good, origin: "http://evil.example"}); w.Code != 403 {
		t.Errorf("login from another origin: %d, want 403", w.Code)
	}
	if w := h.do(req{method: "POST", path: "/api/login", body: good, ctype: "text/plain"}); w.Code != 415 {
		t.Errorf("login as text/plain: %d, want 415", w.Code)
	}
	cookie, csrf := h.login()
	w := h.do(req{path: "/api/me", cookie: cookie})
	if m := decode(t, w); w.Code != 200 || m["csrf"] != csrf || m["interval"] != float64(10) {
		t.Errorf("/api/me after sign-in: %d %v", w.Code, m)
	}
}

func TestLoginIsSlowedAfterTenFailures(t *testing.T) {
	h := newHarness(t)
	for i := 0; i < maxLoginFailures; i++ {
		h.do(req{method: "POST", path: "/api/login", body: `{"token":"nope"}`})
	}
	good := `{"token":"` + h.srv.tokens.current() + `"}`
	if w := h.do(req{method: "POST", path: "/api/login", body: good}); w.Code != 429 {
		t.Errorf("after %d failures the right token got %d, want 429", maxLoginFailures, w.Code)
	}
}

func TestPostsNeedCSRFAndOrigin(t *testing.T) {
	h := newHarness(t)
	cookie, csrf := h.login()
	body := `{"target":"web1:api","text":"hi"}`
	if w := h.do(req{method: "POST", path: "/api/nudge", body: body, cookie: cookie}); w.Code != 403 {
		t.Errorf("no CSRF header: %d, want 403", w.Code)
	}
	if w := h.do(req{method: "POST", path: "/api/nudge", body: body, cookie: cookie, csrf: "x" + csrf}); w.Code != 403 {
		t.Errorf("a wrong CSRF header: %d, want 403", w.Code)
	}
	if w := h.do(req{method: "POST", path: "/api/nudge", body: body, cookie: cookie, csrf: csrf, origin: "http://evil.example"}); w.Code != 403 {
		t.Errorf("another origin: %d, want 403", w.Code)
	}
	if w := h.do(req{method: "POST", path: "/api/nudge", body: body, cookie: cookie, csrf: csrf,
		header: map[string]string{"Sec-Fetch-Site": "cross-site"}}); w.Code != 403 {
		t.Errorf("Sec-Fetch-Site cross-site: %d, want 403", w.Code)
	}
	if w := h.do(req{method: "POST", path: "/api/nudge", body: body, cookie: cookie, csrf: csrf, ctype: "text/plain"}); w.Code != 415 {
		t.Errorf("text/plain: %d, want 415", w.Code)
	}
	if w := h.do(req{method: "POST", path: "/api/nudge", body: body, cookie: cookie, csrf: csrf}); w.Code != 200 {
		t.Errorf("a proper request: %d %s", w.Code, w.Body)
	}
	// A bearer token is never sent by a browser on its own, so a script
	// using one needs neither.
	if w := h.do(req{method: "POST", path: "/api/nudge", body: body, auth: h.srv.tokens.current(), origin: "null"}); w.Code != 200 {
		t.Errorf("bearer without CSRF: %d %s", w.Code, w.Body)
	}
}

func TestNoCORS(t *testing.T) {
	h := newHarness(t)
	if w := h.do(req{method: "OPTIONS", path: "/api/nudge", header: map[string]string{"Origin": "http://evil.example"}}); w.Code != 403 {
		t.Errorf("preflight: %d, want 403", w.Code)
	}
	cookie, _ := h.login()
	w := h.do(req{path: "/api/sessions", cookie: cookie, header: map[string]string{"Origin": "http://evil.example"}})
	for k := range w.Header() {
		if strings.HasPrefix(strings.ToLower(k), "access-control-") {
			t.Errorf("a CORS header was sent: %s", k)
		}
	}
}

func TestTargetsAreCheckedBeforeTheyReachArgv(t *testing.T) {
	for _, bad := range []string{"-rf", "--force", "web1:-x", "a;b", "a b", "a$(x)", "web1:api@la.bel", "web1:api/../x", "", "web1:"} {
		if validTarget(bad) {
			t.Errorf("%q passed the target grammar", bad)
		}
	}
	for _, good := range []string{"api", "web1:api", "web1:my.app/fix-1@review", "jaryan:yektanet42/rafugar@impl"} {
		if !validTarget(good) {
			t.Errorf("%q failed the target grammar", good)
		}
	}
	h := newHarness(t)
	cookie, csrf := h.login()
	if w := h.do(req{method: "POST", path: "/api/stop", body: `{"target":"--all","confirm":"--all"}`, cookie: cookie, csrf: csrf}); w.Code != 400 {
		t.Errorf("an option as a target: %d", w.Code)
	}
}

func TestNudgeSendsTheTextOnStdin(t *testing.T) {
	h := newHarness(t)
	cookie, csrf := h.login()
	text := "line one\nit's $(rm -rf /) `x` \"q\""
	b, _ := json.Marshal(map[string]any{"target": "web1:api", "text": text})
	w := h.do(req{method: "POST", path: "/api/nudge", body: string(b), cookie: cookie, csrf: csrf})
	if w.Code != 200 || decode(t, w)["sent"] != true {
		t.Fatalf("nudge: %d %s", w.Code, w.Body)
	}
	if got := h.file("argv"); got != "--no-color\n--json\nnudge\nweb1:api\n" {
		t.Errorf("argv:\n%s", got)
	}
	if got := h.file("stdin"); got != text {
		t.Errorf("stdin: %q, want %q", got, text)
	}
}

func TestNudgeToANoPermsSessionNeedsTheTargetTyped(t *testing.T) {
	h := newHarness(t)
	cookie, csrf := h.login()
	w := h.do(req{method: "POST", path: "/api/nudge", body: `{"target":"web1:noperms","text":"hi"}`, cookie: cookie, csrf: csrf})
	if w.Code != 428 || decode(t, w)["need_confirm"] != "no-perms" {
		t.Fatalf("no-perms without confirmation: %d %s", w.Code, w.Body)
	}
	if strings.Contains(h.file("argv"), "nudge") {
		t.Error("the nudge ran anyway")
	}
	w = h.do(req{method: "POST", path: "/api/nudge", body: `{"target":"web1:noperms","text":"hi","confirm":"web1:other"}`, cookie: cookie, csrf: csrf})
	if w.Code != 428 {
		t.Errorf("confirmed with the wrong target: %d", w.Code)
	}
	w = h.do(req{method: "POST", path: "/api/nudge", body: `{"target":"web1:noperms","text":"hi","confirm":"web1:noperms"}`, cookie: cookie, csrf: csrf})
	if w.Code != 200 {
		t.Errorf("confirmed: %d %s", w.Code, w.Body)
	}
}

func TestForceNeedsTheTargetTyped(t *testing.T) {
	h := newHarness(t)
	cookie, csrf := h.login()
	w := h.do(req{method: "POST", path: "/api/nudge", body: `{"target":"web1:api","text":"hi","force":true}`, cookie: cookie, csrf: csrf})
	if w.Code != 428 || decode(t, w)["need_confirm"] != "force" {
		t.Fatalf("force without confirmation: %d %s", w.Code, w.Body)
	}
	w = h.do(req{method: "POST", path: "/api/nudge", body: `{"target":"web1:api","text":"hi","force":true,"confirm":"web1:api"}`, cookie: cookie, csrf: csrf})
	if w.Code != 200 || !strings.HasSuffix(h.file("argv"), "nudge\nweb1:api\n--force\n") {
		t.Errorf("force: %d argv:\n%s", w.Code, h.file("argv"))
	}
}

func TestCxErrorsKeepTheirExitCodeAndWords(t *testing.T) {
	h := newHarness(t)
	cookie, csrf := h.login()
	w := h.do(req{method: "POST", path: "/api/nudge", body: `{"target":"web1:missing","text":"hi"}`, cookie: cookie, csrf: csrf})
	m := decode(t, w)
	if w.Code != 404 || m["exit"] != float64(2) || m["error"] != "cx: no such project" {
		t.Errorf("a missing project: %d %v", w.Code, m)
	}
}

func TestStopAndDoneNeedConfirmation(t *testing.T) {
	h := newHarness(t)
	cookie, csrf := h.login()
	if w := h.do(req{method: "POST", path: "/api/stop", body: `{"target":"web1:api"}`, cookie: cookie, csrf: csrf}); w.Code != 428 {
		t.Errorf("stop without confirmation: %d", w.Code)
	}
	if w := h.do(req{method: "POST", path: "/api/stop", body: `{"target":"web1:api","confirm":"web1:api"}`, cookie: cookie, csrf: csrf}); w.Code != 200 {
		t.Errorf("stop: %d %s", w.Code, w.Body)
	}
	if got := h.file("argv"); got != "--no-color\n--json\n-y\nstop\nweb1:api\n" {
		t.Errorf("stop argv:\n%s", got)
	}
	if w := h.do(req{method: "POST", path: "/api/goal", body: `{"host":"web1","name":"g","action":"done"}`, cookie: cookie, csrf: csrf}); w.Code != 428 {
		t.Errorf("done without confirmation: %d", w.Code)
	}
	if w := h.do(req{method: "POST", path: "/api/goal", body: `{"host":"web1","name":"g","action":"pause"}`, cookie: cookie, csrf: csrf}); w.Code != 200 {
		t.Errorf("pause: %d %s", w.Code, w.Body)
	}
	if got := h.file("argv"); got != "--no-color\n--json\ngoal\n--host\nweb1\npause\ng\n" {
		t.Errorf("goal argv:\n%s", got)
	}
	if w := h.do(req{method: "POST", path: "/api/goal", body: `{"host":"web1","name":"g","action":"rm","confirm":"g"}`, cookie: cookie, csrf: csrf}); w.Code != 400 {
		t.Errorf("an action that is not offered: %d", w.Code)
	}
}

func TestOpenPassesRemoteControlOnlyWhenAsked(t *testing.T) {
	h := newHarness(t)
	cookie, csrf := h.login()
	for body, want := range map[string]string{
		`{"target":"web1:api"}`:                        "open\n-d\nweb1:api\n",
		`{"target":"web1:api","remote_control":true}`:  "open\n-d\nweb1:api\n--remote-control\n",
		`{"target":"web1:api","remote_control":false}`: "open\n-d\nweb1:api\n--no-remote-control\n",
	} {
		if w := h.do(req{method: "POST", path: "/api/open", body: body, cookie: cookie, csrf: csrf}); w.Code != 200 {
			t.Errorf("%s: %d", body, w.Code)
		}
		if got := h.file("argv"); !strings.HasSuffix(got, want) {
			t.Errorf("%s: argv\n%s", body, got)
		}
	}
}

func TestTailIsOneReadPerConnection(t *testing.T) {
	h := newHarness(t)
	cookie, _ := h.login()
	w := h.do(req{path: "/api/tail?target=web1:api", cookie: cookie})
	body := w.Body.String()
	if ct := w.Header().Get("Content-Type"); ct != "text/event-stream" {
		t.Errorf("content type %q", ct)
	}
	if !strings.Contains(body, "id: 11111111-2222-3333-4444-555555555555:42\n") || !strings.Contains(body, "event: tail\ndata: {") {
		t.Errorf("first read:\n%s", body)
	}
	// The data line must be one line: the fake printed it across two.
	for _, l := range strings.Split(body, "\n") {
		if strings.HasPrefix(l, "data: ") && !strings.HasSuffix(l, "}") {
			t.Errorf("an event's data spans lines: %q", l)
		}
	}

	w = h.do(req{path: "/api/tail?target=web1:api", cookie: cookie,
		header: map[string]string{"Last-Event-ID": "11111111-2222-3333-4444-555555555555:42"}})
	if got := h.file("argv"); got != "--no-color\n--json\ntail\nweb1:api\n--from\n42\n--uuid\n11111111-2222-3333-4444-555555555555\n" {
		t.Errorf("continuation argv:\n%s", got)
	}
	if b := w.Body.String(); strings.Contains(b, "event:") || !strings.Contains(b, "id: 11111111-2222-3333-4444-555555555555:42\n") || !strings.Contains(b, "retry: 3000") {
		t.Errorf("nothing new should still move the cursor, quietly:\n%s", b)
	}

	h.do(req{path: "/api/tail?target=web1:api", cookie: cookie, header: map[string]string{"Last-Event-ID": "x; rm -rf /:1"}})
	if strings.Contains(h.file("argv"), "--from") {
		t.Error("a malformed Last-Event-ID reached argv")
	}

	w = h.do(req{path: "/api/tail?target=web1:missing", cookie: cookie})
	if b := w.Body.String(); w.Code != 200 || !strings.Contains(b, "event: failure") || !strings.Contains(b, `"permanent":true`) {
		t.Errorf("a missing target:\n%d %s", w.Code, b)
	}
}

func TestSessionsJoinsPeekAndLs(t *testing.T) {
	h := newHarness(t)
	cookie, _ := h.login()
	w := h.do(req{path: "/api/sessions", cookie: cookie})
	m := decode(t, w)
	if w.Code != 200 || m["peek"] == nil || m["ls"] == nil {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	if ws, _ := m["warnings"].([]any); len(ws) != 1 || ws[0] != "warning: web2 unreachable" {
		t.Errorf("warnings: %v", m["warnings"])
	}
}

func TestGoalsFromEveryHost(t *testing.T) {
	h := newHarness(t)
	cookie, _ := h.login()
	w := h.do(req{path: "/api/goals", cookie: cookie})
	var v struct {
		Goals  []map[string]any
		Errors []map[string]string
	}
	if err := json.Unmarshal(w.Body.Bytes(), &v); err != nil || w.Code != 200 {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	if len(v.Goals) != 1 || v.Goals[0]["host"] != "web1" {
		t.Fatalf("goals: %v", v.Goals)
	}
	g := v.Goals[0]
	if _, ok := g["revisions"]; ok {
		t.Error("revisions were sent")
	}
	if log := g["log"].([]any); len(log) != 20 || log[19].(map[string]any)["n"] != float64(24) {
		t.Errorf("log should be the last 20 entries: %v", log)
	}
	if len(v.Errors) != 1 || v.Errors[0]["host"] != "web2" {
		t.Errorf("an unreachable host should be named: %v", v.Errors)
	}
}

func TestPageURLKeepsTheTokenInTheFragment(t *testing.T) {
	if got := pageURL("127.0.0.1:8377", "abc"); got != "http://127.0.0.1:8377/#token=abc" {
		t.Error(got)
	}
	if got := pageURL("0.0.0.0:9000", "abc"); got != "http://127.0.0.1:9000/#token=abc" {
		t.Error(got)
	}
}
