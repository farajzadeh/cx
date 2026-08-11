#!/usr/bin/env bash
# lib/cmd/stop.sh — `cx stop` — end a project's session.

# shellcheck source=../target.sh
. "$CX_HOME/lib/target.sh"

cmd_stop() {
  local target="${1:-}"

  case "$target" in
    -h | --help)
      cat <<EOF
${C_BOLD}cx stop${C_RESET} — end a project's Claude session

  cx stop <host>:<project>

Kills the tmux session. Anything Claude was doing stops; the conversation
history is kept, so cx open resumes where it left off.

To leave a session running and just disconnect, detach instead: Ctrl-b d
EOF
      return 0
      ;;
  esac

  [ -n "$target" ] || {
    err "no target given"
    hint "usage: cx stop <host>:<project>"
    hint "see what is running with: cx status"
    return 3
  }

  cx_target_resolve "$target" || return $?

  local out rc=0
  out=$(cx_agent "$CX_T_HOST" stop "$CX_T_PROJECT") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hint "check the server with: cx host test $CX_T_HOST"
    return "$rc"
  fi

  # Liveness changed, so anything cached about this host is now wrong.
  cx_cache_invalidate "$CX_T_HOST"

  if [ "${CX_JSON:-0}" = 1 ]; then
    printf '%s' "$out" | jq -c --arg h "$CX_T_HOST" '. + {host:$h}'
    return 0
  fi

  if printf '%s' "$out" | jq -e '.stopped' >/dev/null 2>&1; then
    say "  $(ok_mark) stopped $(cx_target_str)"
  else
    note "  no live session for $(cx_target_str)"
  fi
}
