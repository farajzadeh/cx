#!/usr/bin/env bash
# lib/cmd/ask.sh — `cx ask` — one-shot question, no session, no terminal.
#
# The scriptable entry point: works from a cron job, a git hook, or a pipe.
#
# The prompt is sent over STDIN rather than as an argument. That is not a
# convenience — it means the prompt never passes through a shell on either
# side, so quotes, $(...), backticks and newlines are impossible to mangle
# and there is no argv length limit.

# shellcheck source=../target.sh
. "$CX_HOME/lib/target.sh"

cmd_ask() {
  local target="" prompt=""

  case "${1:-}" in
    -h | --help)
      cat <<EOF
${C_BOLD}cx ask${C_RESET} — ask Claude a one-shot question about a project

  cx ask <host>:<project> "your question"
  echo "your question" | cx ask <host>:<project>

Runs in the project directory on the server and prints the answer to stdout.
No tmux session is created and no terminal is required, so this works in
pipes, cron jobs, and git hooks.

  cx ask web1:api "what changed in the last commit?"
  cx ask web1:api "summarise the README" > summary.md
  git diff | cx ask web1:api "review this diff"

A worktree target asks in that worktree's directory:

  cx ask web1:api/authfix "what is left to do on this branch?"

A ${C_BOLD}@label${C_RESET} joins that named session's conversation instead of asking with no
history, so the question lands in the same thread cx open would attach to:

  cx ask web1:api@review "summarise what we decided"

${C_BOLD}OPTIONS${C_RESET}
  --dangerously-skip-permissions
      Answer with all permission checks bypassed, so Claude may edit files and
      run commands without asking. Applies to this one invocation only.
      The warning goes to stderr, so piped output is unaffected.

For an interactive conversation, use cx open instead.
EOF
      return 0
      ;;
  esac

  # The flag is recognised anywhere in the argv; the first remaining word is
  # the target and the rest is the question. Assembled in place rather than
  # re-set with eval, so a prompt containing quotes or $(...) is never
  # re-parsed — the same reason it travels to the server on stdin.
  local dangerous=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dangerously-skip-permissions) dangerous=1 ;;
      *)
        if [ -z "$target" ]; then
          target="$1"
        else
          prompt="${prompt:+$prompt }$1"
        fi
        ;;
    esac
    shift
  done

  [ -n "$target" ] || {
    err "no target given"
    hint 'usage: cx ask <host>:<project> "question"'
    return 3
  }

  cx_target_resolve "$target" || return $?

  # No prompt argument means read stdin, which is what makes piping work.
  if [ -z "$prompt" ]; then
    if [ -t 0 ]; then
      err "no question given"
      hint 'usage: cx ask '"$(cx_target_str)"' "your question"'
      hint "or pipe one in: echo 'question' | cx ask $(cx_target_str)"
      return 3
    fi
    prompt=$(cat)
  fi

  [ -n "$prompt" ] || {
    err "empty question"
    return 3
  }

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

  local danger_args=()
  if [ "$dangerous" = 1 ]; then
    cx_agent_supports "$CX_T_HOST" \
      "--dangerously-skip-permissions" 0.2.1 "$ver" || return 1
    danger_args=(--dangerous)
    # stderr, not stdout: cx ask is built to be piped, and a warning in the
    # answer would corrupt whatever consumes it.
    warn "answering with ALL permission checks bypassed"
  fi

  # Prompt travels on stdin; only the target is passed as arguments.
  cx_target_args
  local opts
  opts=$(cx_ssh_opts)
  # shellcheck disable=SC2086
  printf '%s' "$prompt" |
    ssh $opts "$CX_T_HOST" \
      "$CX_AGENT_PATH$(cx_remote_quote ask "$CX_T_PROJECT" \
        "${CX_T_ARGS[@]+"${CX_T_ARGS[@]}"}" \
        "${danger_args[@]+"${danger_args[@]}"}")"
}
