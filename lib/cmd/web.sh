#!/usr/bin/env bash
# lib/cmd/web.sh — `cx web` — cx live: every session on one page, in a browser.
#
# The one cx command that keeps running, and why that is allowed (invariant
# 11): it only answers requests. It has no timer and no poller; each request
# runs one-shot cx verbs and returns, and the loop is the browser's. The
# server is web/*.go — bash cannot listen on a socket — and everything it
# knows, it learns by running this cx. See docs/WEB.md.
#
# This file only finds that server and execs it: the release's binary when
# install.sh fetched one for this version, or a build from web/*.go with the
# local go, cached under a hash of the sources (a cache under invariant 4:
# delete it and the next run builds again).

CX_WEB_TOKEN="${CX_WEB_TOKEN:-$CX_CONFIG_DIR/web.token}"

# _web_source_key — names a build of these exact sources. cksum is POSIX,
# where md5sum and sha256sum are not everywhere.
_web_source_key() {
  local f
  for f in "$CX_HOME/web/go.mod" "$CX_HOME"/web/*.go; do
    case "$f" in *_test.go) continue ;; esac
    cat "$f"
  done | cksum | awk '{print $1 "-" $2}'
}

# _web_binary REBUILD — the path of a server binary for this cx, building one
# if that is what it takes.
_web_binary() {
  local rebuild="$1" rel="$CX_HOME/web/bin/cx-web" v="" key out tmp
  if [ "$rebuild" != 1 ] && [ -x "$rel" ]; then
    v=$("$rel" --version 2>/dev/null) || v=""
    if [ "$v" = "$CX_VERSION" ]; then
      printf '%s' "$rel"
      return 0
    fi
  fi

  if cx_have go; then
    key=$(_web_source_key) || key=""
    out="$CX_CACHE_DIR/web/cx-web-$key"
    if [ "$rebuild" = 1 ] || [ ! -x "$out" ]; then
      mkdir -p "$CX_CACHE_DIR/web" || return 1
      info "building the cx web server with $(go version 2>/dev/null | awk '{print $3}'), once"
      tmp="$out.tmp.$$"
      # The build's own output is for a person, so it goes to stderr.
      if ! (cd "$CX_HOME/web" &&
        CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$tmp" .) >&2; then
        rm -f "$tmp"
        err "could not build the cx web server"
        hint "it needs Go 1.21 or newer: go version"
        return 1
      fi
      mv -f "$tmp" "$out" || return 1
      # Older builds are for sources that no longer exist.
      local old
      for old in "$CX_CACHE_DIR"/web/cx-web-*; do
        [ "$old" = "$out" ] || rm -f "$old"
      done
    fi
    printf '%s' "$out"
    return 0
  fi

  if [ -x "$rel" ]; then
    info "web/bin/cx-web is from cx ${v:-another version}, not $CX_VERSION; using it, since there is no go to build this one"
    printf '%s' "$rel"
    return 0
  fi
  err "cx web needs its server, and there is neither a release binary nor Go to build one"
  hint "re-run install.sh, which downloads this release's binary,"
  hint "or install Go 1.21 or newer (https://go.dev/dl/) and cx web builds it once"
  return 1
}

cmd_web() {
  local listen="${CX_WEB_LISTEN:-127.0.0.1:8377}" interval="${CX_WEB_INTERVAL:-10}"
  local rebuild=0 mode="" terminal="" allow=()

  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        cat <<EOF
${C_BOLD}cx web${C_RESET} — cx live: watch and steer every session from a browser

  cx web                            serve on 127.0.0.1:8377, print the link to open
  cx web --listen ADDR              somewhere else (host:port); see below first
  cx web --interval N               the board refreshes every N seconds (default 10)
  cx web --allow-host NAME          also answer to NAME, e.g. a reverse proxy's
  cx web --terminal                 also offer a read-only terminal view (needs ttyd)
  cx web --print-url                print the sign-in link again, and exit
  cx web --rotate-token             replace the token, signing every page out
  cx web --rebuild                  build the server again from web/*.go

The board groups sessions by server and goal, blocked ones first, and
refreshes itself while the tab is visible. A session opens into its live
conversation, a box to send it a message (cx nudge, with the same
refusals), and buttons to open it in Claude, start it, or stop it. The
goals tab pauses, resumes and finishes goals. With --terminal, a session
also opens as its own screen, read-only, through ttyd on this machine (cx
open --view); while someone watches, the session counts as attached, so
cx nudge declines it as it would for you in a terminal.

${C_BOLD}Security.${C_RESET} Whoever can use this page can type into your sessions, and
a session with no permission checks runs what it is told: that is remote
code execution on every server cx reaches. So it listens on 127.0.0.1 only,
every request needs the token (kept 0600 in $CX_WEB_TOKEN) or the cookie
it signs in with, and every change needs a CSRF token as well.

${C_BOLD}From a phone${C_RESET}, either:
  an SSH tunnel to the machine running cx web, and open the link there:
    ssh -N -L 8377:127.0.0.1:8377 <that machine>
  or an authenticating reverse proxy with TLS (Caddy, nginx auth_request,
  tailscale serve) in front of 127.0.0.1:8377, with --allow-host <its name>.
Never --listen 0.0.0.0 on a network you do not control. docs/WEB.md has both.

Needs the server binary: install.sh fetches the release's, or Go 1.21+
builds it once into $CX_CACHE_DIR/web.

Related: cx peek, cx nudge, cx tail, cx goal
EOF
        return 0
        ;;
      --listen)
        listen="${2:-}"
        shift
        ;;
      --listen=*) listen="${1#*=}" ;;
      --interval)
        interval="${2:-}"
        shift
        ;;
      --interval=*) interval="${1#*=}" ;;
      --allow-host)
        allow=("${allow[@]+"${allow[@]}"}" --allow-host "${2:-}")
        shift
        ;;
      --allow-host=*) allow=("${allow[@]+"${allow[@]}"}" --allow-host "${1#*=}") ;;
      --rotate-token) mode=--rotate-token ;;
      --print-url) mode=--print-url ;;
      --rebuild) rebuild=1 ;;
      --terminal) terminal=--terminal ;;
      *)
        err "unknown option: $1"
        hint "see: cx web --help"
        return 3
        ;;
    esac
    shift
  done

  case "$listen" in
    *:[0-9]*) ;;
    *)
      err "--listen wants host:port, e.g. 127.0.0.1:8377"
      return 3
      ;;
  esac
  case "$interval" in '' | *[!0-9]*)
    err "--interval wants a number of seconds"
    return 3
    ;;
  esac

  local bin
  bin=$(_web_binary "$rebuild") || return 1

  # The token file holds the key to every session cx can reach: nothing
  # created on the way to it may be readable by anyone else.
  umask 077
  exec "$bin" --listen "$listen" --interval "$interval" \
    --cx "$CX_HOME/bin/cx" --page "$CX_HOME/web/index.html" \
    --token-file "$CX_WEB_TOKEN" --cx-version "$CX_VERSION" \
    "${allow[@]+"${allow[@]}"}" ${terminal:+"$terminal"} ${mode:+"$mode"}
}
