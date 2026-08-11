#!/usr/bin/env bash
# lib/cmd/login.sh — `cx login` — one-time interactive Claude Code sign-in.
#
# Deliberately thin. cx does not touch credentials: it opens an interactive
# Claude Code session on the server and gets out of the way. Nothing about the
# sign-in passes through the client, and no credential ever leaves the server.

# shellcheck source=../hosts.sh
. "$CX_HOME/lib/hosts.sh"
# shellcheck source=../remote.sh
. "$CX_HOME/lib/remote.sh"

cmd_login() {
  local alias="${1:-}"

  case "$alias" in
    -h | --help)
      cat <<USAGE
${C_BOLD}cx login${C_RESET} — sign in to Claude Code on a server

  cx login <host>

Opens an interactive Claude Code session on the server so you can complete
sign-in there. Credentials are stored on that server and never reach this
machine — which is the whole point of cx's design.

Run once per server. Check status any time with: cx host test <host>
USAGE
      return 0
      ;;
  esac

  [ -n "$alias" ] || {
    err "usage: cx login <host>"
    return 3
  }
  cx_host_exists "$alias" || {
    err "unknown host: $alias"
    hint "add it with: cx host add"
    return 2
  }

  if ! cx_agent "$alias" version >/dev/null 2>&1; then
    err "the cx agent is not installed on $alias"
    hint "install it first: cx provision $alias"
    return 1
  fi

  note "Starting Claude Code on $alias."
  note "Complete the sign-in, then exit (Ctrl-D) to return here."
  say ""

  # BatchMode off and a TTY: the sign-in flow is interactive by nature.
  local opts
  opts=$(CX_SSH_BATCH=no cx_ssh_opts)
  # shellcheck disable=SC2086
  ssh -t $opts "$alias" 'exec $HOME/.local/bin/claude || exec claude' || true

  say ""
  printf '  verifying... '
  if cx_agent "$alias" doctor 2>/dev/null | jq -e '.claude.logged_in' >/dev/null 2>&1; then
    say "$(ok_mark) signed in"
    cx_cache_invalidate "$alias"
  else
    say "$(bad_mark) still not signed in"
    hint "try again: cx login $alias"
    return 1
  fi
}
