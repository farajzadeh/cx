#!/usr/bin/env bash
# lib/cmd/open.sh — `cx open`, `cx resume`, `cx shell`.
#
# All three are the same operation with a different mode. The client's only
# job is to resolve the target and hand over a TTY: every decision about tmux
# and Claude lives in the agent, where no quoting can go wrong.

# shellcheck source=../target.sh
. "$CX_HOME/lib/target.sh"

_open_common() {
  local mode="$1" target="${2:-}"

  [ -n "$target" ] || {
    err "no target given"
    hint "usage: cx $mode <host>:<project>"
    hint "see what exists with: cx ls"
    return 3
  }

  cx_target_resolve "$target" || return $?

  if ! cx_agent "$CX_T_HOST" version >/dev/null 2>&1; then
    err "the cx agent is not installed on $CX_T_HOST"
    hint "install it with: cx provision $CX_T_HOST"
    return 1
  fi

  # A live session means work is already in flight; opening it is safe even if
  # Claude was never signed in on this server, so only warn when creating one.
  if ! cx_agent "$CX_T_HOST" doctor 2>/dev/null | jq -e '.claude.logged_in' >/dev/null 2>&1; then
    if [ "$mode" != shell ]; then
      warn "Claude Code is not signed in on $CX_T_HOST"
      hint "sign in once with: cx login $CX_T_HOST"
      say ""
    fi
  fi

  # Opening changes tmux liveness, which cx ls and cx status report.
  cx_cache_invalidate "$CX_T_HOST"

  # Hand over the terminal. exec so cx does not linger as a parent process for
  # the whole session, and so Ctrl-C reaches tmux rather than us.
  local opts
  opts=$(CX_SSH_BATCH=no cx_ssh_opts)
  # shellcheck disable=SC2086
  exec ssh -t $opts "$CX_T_HOST" \
    "$CX_AGENT_PATH$(cx_remote_quote open "$CX_T_PROJECT" --mode "$mode")"
}

cmd_open() {
  case "${1:-}" in
    -h | --help)
      cat <<EOF
${C_BOLD}cx open${C_RESET} — attach a Claude session for a project

  cx open <host>:<project>

Creates a persistent tmux session on the server and starts Claude Code in it,
resuming the previous conversation. If a session is already running, this
reattaches to it instead of starting a second one.

The session survives disconnection: close your laptop, and Claude keeps
working. Reattach with the same command. Detach without stopping: Ctrl-b d

Related: cx resume (pick an older conversation), cx shell (no Claude)
EOF
      return 0
      ;;
  esac
  _open_common continue "$@"
}

cmd_resume() {
  case "${1:-}" in
    -h | --help)
      cat <<EOF
${C_BOLD}cx resume${C_RESET} — attach and choose which conversation to resume

  cx resume <host>:<project>

Like cx open, but starts Claude Code's session picker so you can choose an
earlier conversation instead of continuing the most recent one.
EOF
      return 0
      ;;
  esac
  _open_common resume "$@"
}

cmd_shell() {
  case "${1:-}" in
    -h | --help)
      cat <<EOF
${C_BOLD}cx shell${C_RESET} — a plain shell in the project directory

  cx shell <host>:<project>

Same persistent tmux session as cx open, without starting Claude Code.
EOF
      return 0
      ;;
  esac
  _open_common shell "$@"
}
