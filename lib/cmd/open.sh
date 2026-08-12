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

  # One version call serves both checks: is the agent there at all, and is it
  # new enough for the worktree/session flags this target needs.
  local ver=""
  ver=$(cx_agent "$CX_T_HOST" version 2>/dev/null) || true
  if [ -z "$ver" ]; then
    err "the cx agent is not installed on $CX_T_HOST"
    hint "install it with: cx provision $CX_T_HOST"
    return 1
  fi
  if cx_target_needs_units; then
    cx_agent_units_ok "$CX_T_HOST" "$ver" || return 1
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
  cx_target_args
  local opts
  opts=$(CX_SSH_BATCH=no cx_ssh_opts)
  # shellcheck disable=SC2086
  exec ssh -t $opts "$CX_T_HOST" \
    "$CX_AGENT_PATH$(cx_remote_quote open "$CX_T_PROJECT" \
      "${CX_T_ARGS[@]+"${CX_T_ARGS[@]}"}" --mode "$mode")"
}

cmd_open() {
  case "${1:-}" in
    -h | --help)
      cat <<EOF
${C_BOLD}cx open${C_RESET} — attach a Claude session

  cx open <host>:<project>                  the project's default session
  cx open <host>:<project>@<label>          a second, independent session
  cx open <host>:<project>/<worktree>       a worktree of the project
  cx open <host>:<project>/<worktree>@<label>

Creates a persistent tmux session on the server and starts Claude Code in it,
resuming that session's own conversation. If it is already running, this
reattaches instead of starting a second one.

Each ${C_BOLD}@label${C_RESET} is a separate conversation, so you can run several in parallel
on one project and come back to any of them:

  cx open web1:api                 keep working on the main thread
  cx open web1:api@review          a review thread, same files, own history
  cx stop web1:api@review          end just that one

For parallel work on separate ${C_BOLD}branches${C_RESET}, give each task a worktree instead —
see cx wt. Labels share a directory; worktrees do not.

The session survives disconnection: close your laptop, and Claude keeps
working. Reattach with the same command. Detach without stopping: Ctrl-b d

Related: cx wt (worktrees), cx resume (pick an older conversation),
         cx shell (no Claude), cx status (what is running)
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

  cx resume <host>:<project>[/<worktree>][@<label>]

Like cx open, but starts Claude Code's session picker so you can choose any
earlier conversation in that directory instead of the one cx would pick.

Note that what you choose in the picker is not remembered: the next cx open
goes back to that session's own conversation. To keep a second thread you can
return to by name, use a label — cx open <target>@<label>.
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

  cx shell <host>:<project>[/<worktree>][@<label>]

Same persistent tmux session as cx open, without starting Claude Code. A
worktree target opens a shell in that worktree's directory.
EOF
      return 0
      ;;
  esac
  _open_common shell "$@"
}
