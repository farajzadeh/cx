#!/usr/bin/env bash
# lib/cmd/stop.sh — `cx stop` — end a project's session.

# shellcheck source=../target.sh
. "$CX_HOME/lib/target.sh"

cmd_stop() {
  local target="" all=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --all) all=1 ;;
      -h | --help)
        cat <<EOF
${C_BOLD}cx stop${C_RESET} — end a Claude session

  cx stop <host>:<project>                one session: the project's default
  cx stop <host>:<project>@<label>        one named session
  cx stop <host>:<project>/<worktree>     a worktree's default session
  cx stop <host>:<project> --all          every session of the project,
                                          its labelled ones and its worktrees'

Kills the tmux session. Anything Claude was doing stops; the conversation
history is kept, so cx open resumes where it left off.

Without --all this stops exactly the session named and nothing else, so
stopping web1:api leaves web1:api@review running.

To leave a session running and just disconnect, detach instead: Ctrl-b d
EOF
        return 0
        ;;
      -*)
        err "unknown option: $1"
        return 3
        ;;
      *) [ -z "$target" ] && target="$1" ;;
    esac
    shift
  done

  [ -n "$target" ] || {
    err "no target given"
    hint "usage: cx stop <host>:<project>[@<label>]"
    hint "see what is running with: cx status"
    return 3
  }

  cx_target_resolve "$target" || return $?

  if cx_target_needs_units || [ "$all" = 1 ]; then
    cx_agent_units_ok "$CX_T_HOST" || return 1
  fi

  cx_target_args
  local out rc=0
  if [ "$all" = 1 ]; then
    out=$(cx_agent "$CX_T_HOST" stop "$CX_T_PROJECT" \
      "${CX_T_ARGS[@]+"${CX_T_ARGS[@]}"}" --all) || rc=$?
  else
    out=$(cx_agent "$CX_T_HOST" stop "$CX_T_PROJECT" \
      "${CX_T_ARGS[@]+"${CX_T_ARGS[@]}"}") || rc=$?
  fi
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
    local n=1
    n=$(printf '%s' "$out" | jq -r '.killed // 1' 2>/dev/null) || n=1
    if [ "$all" = 1 ] && [ "${n:-1}" -gt 1 ]; then
      say "  $(ok_mark) stopped $n sessions for $(cx_target_str)"
    else
      say "  $(ok_mark) stopped $(cx_target_str)"
    fi
  else
    note "  no live session for $(cx_target_str)"
    [ "$all" = 1 ] || hint "other sessions may still be running: cx status"
  fi
}
