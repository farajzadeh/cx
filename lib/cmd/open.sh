#!/usr/bin/env bash
# lib/cmd/open.sh — `cx open`, `cx resume`, `cx shell`.
#
# All three are the same operation with a different mode. The client's only
# job is to resolve the target and hand over a TTY: every decision about tmux
# and Claude lives in the agent, where no quoting can go wrong.

# shellcheck source=../target.sh
. "$CX_HOME/lib/target.sh"

_open_common() {
  local mode="$1" target="" used=0
  shift

  cx_claude_opts_reset
  local passthru=()

  while [ $# -gt 0 ]; do
    # Everything after `--` goes to Claude Code verbatim. Collected first so a
    # passed-through flag is never mistaken for one of ours.
    if [ "$1" = "--" ]; then
      shift
      while [ $# -gt 0 ]; do
        passthru=("${passthru[@]+"${passthru[@]}"}" "$1")
        shift
      done
      break
    fi

    # Captured explicitly rather than testing $? inside an elif, where it
    # would silently start referring to whatever ran last.
    local rc=0
    used=$(cx_claude_opt "$1" "${2:-}") || rc=$?
    if [ "$rc" = 0 ]; then
      shift "$used"
      continue
    fi
    [ "$rc" = 2 ] && return 3 # cx_claude_opt already said what was wrong

    case "$1" in
      -*)
        err "unknown option: $1"
        hint "to pass it to Claude Code instead: cx $mode <target> -- $1"
        return 3
        ;;
      *) [ -z "$target" ] && target="$1" ;;
    esac
    shift
  done

  [ -n "$target" ] || {
    err "no target given"
    hint "usage: cx $mode <host>:<project>"
    hint "see what exists with: cx ls"
    return 3
  }

  if [ "$mode" = shell ] &&
    { cx_claude_needs_agent || [ ${#passthru[@]} -gt 0 ]; }; then
    err "cx shell starts no Claude, so Claude options have no effect"
    hint "use cx open for a Claude session"
    return 3
  fi

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
  cx_claude_opts_ok "$CX_T_HOST" "$ver" || return 1
  if [ ${#passthru[@]} -gt 0 ]; then
    cx_agent_supports "$CX_T_HOST" "passing arguments through to Claude Code" \
      0.3.0 "$ver" || return 1
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

  # Said before handing over the terminal, because once tmux has it the
  # scrollback belongs to Claude and this would scroll away unread.
  cx_target_args
  if [ "$CX_CLAUDE_PERM_MODE" = bypassPermissions ]; then
    warn "Starting $(cx_target_str) with ALL permission checks bypassed."
    note "  Claude will edit files and run commands without asking."
    note "  Only sensible on a server you can afford to have broken."
    say ""
  fi

  # The passthrough goes last, after `--`, so the agent can tell cx's own
  # options from the ones it must hand to Claude Code untouched.
  local sep=()
  [ ${#passthru[@]} -gt 0 ] && sep=(--)

  # Hand over the terminal. exec so cx does not linger as a parent process for
  # the whole session, and so Ctrl-C reaches tmux rather than us.
  local opts
  opts=$(CX_SSH_BATCH=no cx_ssh_opts)
  # shellcheck disable=SC2086
  exec ssh -t $opts "$CX_T_HOST" \
    "$CX_AGENT_PATH$(cx_remote_quote open "$CX_T_PROJECT" \
      "${CX_T_ARGS[@]+"${CX_T_ARGS[@]}"}" --mode "$mode" \
      "${CX_CLAUDE_ARGS[@]+"${CX_CLAUDE_ARGS[@]}"}" \
      "${sep[@]+"${sep[@]}"}" "${passthru[@]+"${passthru[@]}"}")"
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

${C_BOLD}OPTIONS${C_RESET}
  --permission-mode <mode>
      How much Claude asks before acting. One of:
        acceptEdits         apply edits, still ask before running commands
        plan                plan only, change nothing
        auto | manual | dontAsk
        bypassPermissions   ask for nothing at all
  --dangerously-skip-permissions
      The loud spelling of --permission-mode bypassPermissions: Claude edits
      files and runs commands without asking. Claude Code recommends this only
      for sandboxes with no internet access.
  --model <model>       opus, sonnet, haiku, or a full model id
  --effort <level>      low, medium, high, xhigh, max
  -- <args...>          everything after -- goes to Claude Code verbatim

All of these apply when the session is ${C_BOLD}created${C_RESET}, not when you reattach: a
live session cannot be reconfigured, so to change one, cx stop the session and
open it again. cx records the permission mode and shows it in cx status,
because otherwise there is no way to tell from inside a session.

  cx open web1:api --permission-mode acceptEdits
  cx open web1:api --model opus --effort high
  cx open web1:api -- --add-dir /srv/shared

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

Takes --dangerously-skip-permissions as cx open does; see cx open --help.
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
