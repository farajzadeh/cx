#!/usr/bin/env bash
# Unit tests for lib/cmd/web.sh: how cx web finds its server, and what it
# hands that server. The server itself is Go and has its own tests
# (web/server_test.go, run by test/run.sh when go is installed).
#
# Which binary runs is the part with the most ways to be quietly wrong: a
# release binary from another version, a build of sources that have since
# changed, or a cache that outlives them. So each is pinned.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-web.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../../lib/compat.sh
. "$ROOT/lib/compat.sh"
# shellcheck source=../../lib/config.sh
. "$ROOT/lib/config.sh"
# shellcheck source=../../lib/ui.sh
. "$ROOT/lib/ui.sh"

# A CX_HOME of our own, so that a web/bin/cx-web in the real checkout (a
# developer's build) cannot decide anything here.
export CX_HOME="$TMP/home"
mkdir -p "$CX_HOME/web" "$CX_HOME/bin"
printf 'module x\n' >"$CX_HOME/web/go.mod"
printf 'package main\n' >"$CX_HOME/web/main.go"
printf 'package main // a test\n' >"$CX_HOME/web/main_test.go"
CX_CACHE_DIR="$TMP/cache"
# shellcheck disable=SC2034  # read by lib/cmd/web.sh
CX_VERSION=1.2.3
# shellcheck disable=SC2034
CX_WEB_TOKEN="$TMP/config/web.token"

# shellcheck source=../../lib/cmd/web.sh
. "$ROOT/lib/cmd/web.sh"

# go, as far as cx web can tell: `go version` and `go build -o OUT .`, where
# OUT becomes a server that prints its argv and umask. Counted, so a test can
# say whether it built.
HAVE_GO=1
cx_have() { [ "$1" = go ] && [ "$HAVE_GO" = 1 ]; }
go() {
  case "$1" in
    version) printf 'go version go1.22.0 linux/amd64\n' ;;
    build)
      printf 'build\n' >>"$TMP/go.log"
      local out=""
      while [ $# -gt 0 ]; do
        [ "$1" = -o ] && out="$2"
        shift
      done
      server "$out" built
      ;;
  esac
}
builds() { if [ -f "$TMP/go.log" ]; then grep -c . "$TMP/go.log"; else echo 0; fi; }

# server PATH NAME — a stand-in server binary: answers --version with
# $SERVER_VERSION, and otherwise prints its name, its umask and its argv.
SERVER_VERSION=1.2.3
server() {
  cat >"$1" <<EOF
#!/bin/sh
if [ "\$1" = --version ]; then echo "$SERVER_VERSION"; exit 0; fi
echo "$2"
umask
printf '%s\n' "\$@"
EOF
  chmod +x "$1"
}

describe "cx web: which server runs"

it "the release binary, when it is this version's"
mkdir -p "$CX_HOME/web/bin"
server "$CX_HOME/web/bin/cx-web" release
assert_eq "$(_web_binary 0 2>/dev/null)" "$CX_HOME/web/bin/cx-web"
assert_eq "$(builds)" 0

it "a build from source, when the release binary is another version's"
SERVER_VERSION=1.0.0 server "$CX_HOME/web/bin/cx-web" release
bin=$(_web_binary 0 2>/dev/null)
case "$bin" in "$CX_CACHE_DIR/web/cx-web-"*) _t_ok "$_T_NAME" ;; *) _t_fail "$_T_NAME" "got: $bin" ;; esac
assert_eq "$(builds)" 1

it "and only once for the same sources"
assert_eq "$(_web_binary 0 2>/dev/null)" "$bin"
assert_eq "$(builds)" 1

it "a test file does not count as a source"
printf 'package main // changed\n' >"$CX_HOME/web/main_test.go"
assert_eq "$(_web_binary 0 2>/dev/null)" "$bin"

it "changed sources build again, and the old build is removed"
printf 'package main // changed\n' >"$CX_HOME/web/main.go"
bin2=$(_web_binary 0 2>/dev/null)
assert_ne "$bin2" "$bin"
assert_eq "$(builds)" 2
assert_eq "$(find "$CX_CACHE_DIR/web" -type f | grep -c .)" 1

it "--rebuild builds even when there is a build"
_web_binary 1 >/dev/null 2>&1
assert_eq "$(builds)" 3

it "--rebuild builds even when the release binary is this version's"
server "$CX_HOME/web/bin/cx-web" release
_web_binary 1 >/dev/null 2>&1
assert_eq "$(builds)" 4

it "without go, another version's release binary is used, and said so"
HAVE_GO=0
SERVER_VERSION=1.0.0 server "$CX_HOME/web/bin/cx-web" release
assert_eq "$(_web_binary 0 2>"$TMP/err")" "$CX_HOME/web/bin/cx-web"
assert_contains "$(cat "$TMP/err")" "not 1.2.3"

it "with neither, it fails and says what to get"
rm -f "$CX_HOME/web/bin/cx-web"
_web_binary 0 >/dev/null 2>"$TMP/err"
assert_eq "$?" 1
assert_contains "$(cat "$TMP/err")" "install Go 1.21"

describe "cx web: what the server is told"
HAVE_GO=0
server "$CX_HOME/web/bin/cx-web" release

out=$( (cmd_web --listen 127.0.0.1:9000 --allow-host a.example --allow-host=b.example --print-url) 2>/dev/null)
it "its page, the token file, this cx, and the flags as given"
assert_eq "$(printf '%s\n' "$out" | sed -n '3,$p' | tr '\n' ' ')" \
  "--listen 127.0.0.1:9000 --interval 10 --cx $CX_HOME/bin/cx --page $CX_HOME/web/index.html --token-file $TMP/config/web.token --cx-version 1.2.3 --allow-host a.example --allow-host b.example --print-url "
it "under a umask that keeps the token private"
assert_eq "$(printf '%s\n' "$out" | sed -n 2p)" 0077

it "CX_WEB_LISTEN and CX_WEB_INTERVAL are the defaults"
out=$( (CX_WEB_LISTEN=127.0.0.1:7000 CX_WEB_INTERVAL=30 cmd_web) 2>/dev/null)
assert_contains "$out" "127.0.0.1:7000"
assert_contains "$(printf '%s\n' "$out" | tr '\n' ' ')" "--interval 30 "

it "refuses a --listen with no port"
(cmd_web --listen 0.0.0.0) >/dev/null 2>&1
assert_eq "$?" 3
it "refuses an --interval that is not a number"
(cmd_web --interval soon) >/dev/null 2>&1
assert_eq "$?" 3
it "refuses an option it does not know"
(cmd_web --open) >/dev/null 2>&1
assert_eq "$?" 3

summary
