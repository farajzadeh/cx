#!/usr/bin/env bash
# lib/target.sh — resolving targets.
#
# GRAMMAR
#   [host:]project[/worktree][@session]
#
#   web1:api                  the project's default session
#   web1:api@review           a second, independent session on the same files
#   web1:api/authfix          a git worktree of the project
#   web1:api/authfix@tests    a named session inside that worktree
#
# The two separators are free to use because neither is legal in a project
# name (the agent's _validate_name has always rejected `/`, and `@` falls
# outside its allowed character class), so parsing is unambiguous and no
# existing target changes meaning.
#
# Resolution order for the host:
#   1. explicit          web1:api
#   2. CX_DEFAULT_HOST   api          (when configured)
#   3. unique match      api          (searched across every host)
#
# Step 3 is the convenience that makes bare names usable day to day, and also
# the one that can be wrong. When a name exists on more than one server we
# refuse and list the candidates rather than guessing — silently opening the
# wrong server's project is a far worse outcome than one extra keystroke.
#
# Sets CX_T_HOST, CX_T_PROJECT, CX_T_WORKTREE, CX_T_SESSION. Returns:
#   0 resolved
#   2 no such project / no such host
#   3 usage error
#   5 ambiguous

[ -n "${_CX_TARGET_LOADED:-}" ] && return 0
_CX_TARGET_LOADED=1

# shellcheck source=hosts.sh
. "$CX_HOME/lib/hosts.sh"
# shellcheck source=projects.sh
. "$CX_HOME/lib/projects.sh"

CX_T_HOST=""
CX_T_PROJECT=""
CX_T_WORKTREE=""
CX_T_SESSION=""

# Worktree names and session labels are checked here as well as on the server.
# Not redundant: the client turns them into an error the user can read before
# paying for a round trip, and the server cannot trust the client anyway.
_cx_target_label_ok() {
  case "$1" in
    "" | -*) return 1 ;;
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  return 0
}

# cx_target_split TARGET — populate the CX_T_* variables syntactically.
# No network access; used where the project need not exist yet (cx new).
cx_target_split() {
  local t="$1" rest
  CX_T_HOST=""
  CX_T_PROJECT=""
  CX_T_WORKTREE=""
  CX_T_SESSION=""

  case "$t" in
    *:*)
      CX_T_HOST="${t%%:*}"
      rest="${t#*:}"
      ;;
    *)
      rest="$t"
      CX_T_HOST="${CX_DEFAULT_HOST:-}"
      ;;
  esac

  # Session first, then worktree: the label is the outermost component, so
  # peeling it off leaves a plain unit behind.
  case "$rest" in
    *@*)
      CX_T_SESSION="${rest#*@}"
      rest="${rest%%@*}"
      _cx_target_label_ok "$CX_T_SESSION" || {
        err "invalid session label: ${CX_T_SESSION:-(empty)}"
        hint "labels may use letters, digits, underscore and hyphen"
        return 3
      }
      ;;
  esac

  case "$rest" in
    */*)
      CX_T_WORKTREE="${rest#*/}"
      rest="${rest%%/*}"
      _cx_target_label_ok "$CX_T_WORKTREE" || {
        err "invalid worktree name: ${CX_T_WORKTREE:-(empty)}"
        hint "worktree names may use letters, digits, underscore and hyphen"
        return 3
      }
      ;;
  esac

  CX_T_PROJECT="$rest"
  [ -n "$CX_T_PROJECT" ] || return 3
  return 0
}

# cx_target_args — the worktree/session flags for an agent call, as an array.
#
# Emitted only when non-empty, so a plain `cx open web1:api` sends exactly the
# argv it always did and keeps working against an agent that predates them.
# An array rather than a string because the alternative is building a command
# line, which is the thing lib/remote.sh exists to prevent.
cx_target_args() {
  CX_T_ARGS=()
  if [ -n "$CX_T_WORKTREE" ]; then
    CX_T_ARGS=("${CX_T_ARGS[@]+"${CX_T_ARGS[@]}"}" --worktree "$CX_T_WORKTREE")
  fi
  if [ -n "$CX_T_SESSION" ]; then
    CX_T_ARGS=("${CX_T_ARGS[@]+"${CX_T_ARGS[@]}"}" --session "$CX_T_SESSION")
  fi
  return 0
}

# cx_target_needs_units — does this target use anything an old agent lacks?
cx_target_needs_units() {
  [ -n "$CX_T_WORKTREE" ] || [ -n "$CX_T_SESSION" ]
}

# cx_agent_supports HOST FEATURE MINVER [VERSION] — version gate, or explain.
#
# Only called when a command actually needs the newer flag, so the common path
# pays nothing. Without it the failure is "cx-agent: unknown option: --foo",
# which does not tell anyone to re-provision.
#
# Pass VERSION when you already have it: most callers have just run `version`
# or `doctor` for their own reasons, and a second round trip per command is
# the difference between a driver polling six sessions in one second and six.
cx_agent_supports() {
  local host="$1" feature="$2" min="$3" ver="${4:-}"
  [ -n "$ver" ] || ver=$(cx_agent "$host" version 2>/dev/null) || true
  [ -n "$ver" ] || return 0 # not installed: the caller reports that already
  cx_version_ge "$ver" "$min" && return 0
  err "the cx agent on $host is too old for $feature"
  hint "it reports $ver; this needs $min or newer"
  hint "update it with: cx provision $host"
  return 1
}

# The gated features. One implementation above; the minimum version lives at
# the call site, next to the name of the thing it gates.
cx_agent_units_ok() {
  cx_agent_supports "$1" "worktrees and named sessions" 0.2.0 "${2:-}"
}

cx_agent_observe_ok() {
  cx_agent_supports "$1" "observing and steering sessions" 0.3.0 "${2:-}"
}

cx_agent_goals_ok() {
  cx_agent_supports "$1" "goals" 0.3.0 "${2:-}"
}

# ---------------------------------------------------------------------------
# Claude options
# ---------------------------------------------------------------------------
#
# The options cx forwards to Claude Code, shared by open/resume and ask
# because both mean exactly the same thing by them. Validated here so a typo
# costs nothing — for cx open the alternative is a tmux session that appears
# to start and is really a dead shell, with claude's error already gone.

# Set by cx_claude_opt; append to an agent invocation as
#   "${CX_CLAUDE_ARGS[@]+"${CX_CLAUDE_ARGS[@]}"}"
CX_CLAUDE_ARGS=()
CX_CLAUDE_PERM_MODE=""
CX_CLAUDE_MIN_AGENT=""
CX_CLAUDE_USED=0

cx_claude_opts_reset() {
  CX_CLAUDE_ARGS=()
  CX_CLAUDE_PERM_MODE=""
  CX_CLAUDE_MIN_AGENT=""
  CX_CLAUDE_USED=0
}

_cx_claude_add() {
  CX_CLAUDE_ARGS=("${CX_CLAUDE_ARGS[@]+"${CX_CLAUDE_ARGS[@]}"}" "$@")
}

# _cx_claude_need VERSION — raise the agent version these options require.
#
# Per-option rather than one blanket minimum, so someone on an agent that
# already understands a flag is not told to re-provision for it.
_cx_claude_need() {
  if [ -z "$CX_CLAUDE_MIN_AGENT" ] || ! cx_version_ge "$CX_CLAUDE_MIN_AGENT" "$1"; then
    CX_CLAUDE_MIN_AGENT="$1"
  fi
}

# cx_claude_opt FLAG [VALUE] — consume one option, or return 1 if unrecognised.
#
# Sets CX_CLAUDE_USED to how many argv words it took, so the caller's loop
# knows whether to shift once or twice. Returns 1 when FLAG is not ours, which
# is how each command keeps its own options separate from these.
#
# CALL IT DIRECTLY, NEVER AS `used=$(cx_claude_opt ...)`. It reports the word
# count through a global for exactly that reason: this function's real work is
# mutating CX_CLAUDE_ARGS, CX_CLAUDE_PERM_MODE and CX_CLAUDE_MIN_AGENT, and a
# command substitution runs it in a subshell where all three are discarded the
# moment it returns. That failed silently and completely — the word count came
# back correct, so argv was consumed properly and every option parsed without
# complaint, while --permission-mode, --model, --effort and
# --dangerously-skip-permissions all reached nothing at all.
# shellcheck disable=SC2034  # CX_CLAUDE_USED/PERM_MODE are read by lib/cmd/*
cx_claude_opt() {
  local flag="$1" value="${2:-}"

  case "$flag" in
    --permission-mode)
      case "$value" in
        acceptEdits | auto | bypassPermissions | manual | dontAsk | plan) ;;
        "")
          err "--permission-mode needs a value"
          hint "one of: acceptEdits, auto, bypassPermissions, manual, dontAsk, plan"
          return 2
          ;;
        *)
          err "unknown permission mode: $value"
          hint "one of: acceptEdits, auto, bypassPermissions, manual, dontAsk, plan"
          return 2
          ;;
      esac
      CX_CLAUDE_PERM_MODE="$value"
      _cx_claude_add --permission-mode "$value"
      _cx_claude_need 0.3.0
      CX_CLAUDE_USED=2
      ;;
    # The loud spelling of one particular mode, kept because it is what Claude
    # Code itself calls the thing and what people search for.
    --dangerously-skip-permissions)
      CX_CLAUDE_PERM_MODE=bypassPermissions
      _cx_claude_add --dangerous
      _cx_claude_need 0.2.1
      CX_CLAUDE_USED=1
      ;;
    --model)
      [ -n "$value" ] || {
        err "--model needs a value (e.g. opus, sonnet, haiku, or a full model id)"
        return 2
      }
      _cx_claude_add --model "$value"
      _cx_claude_need 0.3.0
      CX_CLAUDE_USED=2
      ;;
    --effort)
      case "$value" in
        low | medium | high | xhigh | max) ;;
        *)
          err "unknown effort level: ${value:-(missing)}"
          hint "one of: low, medium, high, xhigh, max"
          return 2
          ;;
      esac
      _cx_claude_add --effort "$value"
      _cx_claude_need 0.3.0
      CX_CLAUDE_USED=2
      ;;
    *) return 1 ;;
  esac
  return 0
}

# cx_claude_needs_agent — were any of these options given at all?
cx_claude_needs_agent() {
  [ -n "$CX_CLAUDE_MIN_AGENT" ]
}

# cx_claude_opts_ok HOST [VERSION] — the version gate for whatever was given.
cx_claude_opts_ok() {
  [ -n "$CX_CLAUDE_MIN_AGENT" ] || return 0
  cx_agent_supports "$1" "these Claude options" "$CX_CLAUDE_MIN_AGENT" "${2:-}"
}

# cx_target_resolve TARGET — resolve fully, consulting servers if needed.
cx_target_resolve() {
  local t="${1:-}"
  [ -n "$t" ] || {
    err "no target given"
    hint "usage: cx <command> <host>:<project>   (or just <project>)"
    return 3
  }

  # cx_target_split reports its own syntax errors (they are specific enough to
  # be worth saying), so only add the generic one when it stayed silent.
  cx_target_split "$t" || {
    [ -n "$CX_T_PROJECT" ] || err "invalid target: $t"
    return 3
  }

  # Explicit or defaulted host: verify it exists, then we are done.
  if [ -n "$CX_T_HOST" ]; then
    if ! cx_host_exists "$CX_T_HOST"; then
      err "unknown host: $CX_T_HOST"
      local hosts
      hosts=$(cx_hosts_list | tr '\n' ' ')
      if [ -n "$hosts" ]; then
        hint "configured hosts: $hosts"
      else
        hint "add one with: cx host add"
      fi
      return 2
    fi
    return 0
  fi

  # Bare name with no default: search every host.
  local matches count
  matches=$(cx_project_find "$CX_T_PROJECT")
  count=$(printf '%s' "$matches" | grep -c . || true)

  case "$count" in
    0)
      err "no project named '$CX_T_PROJECT' on any server"
      hint "list what exists with: cx ls"
      hint "or create it with:     cx new <host>:$CX_T_PROJECT"
      return 2
      ;;
    1)
      CX_T_HOST=$(printf '%s' "$matches" | head -1 | cut -f1)
      return 0
      ;;
    *)
      err "'$CX_T_PROJECT' exists on more than one server:"
      printf '%s\n' "$matches" | while IFS="$(printf '\t')" read -r h n; do
        [ -n "$h" ] && printf '      %s:%s\n' "$h" "$n" >&2
      done
      hint "name the host explicitly, e.g. $(printf '%s' "$matches" | head -1 | cut -f1):$CX_T_PROJECT"
      # Distinct from "not found" so scripts can tell the two apart.
      return 5
      ;;
  esac
}

# cx_target_str — the full target, as the user would type it, for messages.
cx_target_str() {
  printf '%s:%s' "$CX_T_HOST" "$(cx_target_unit_str)"
}

# cx_target_unit_str — the target without its host: project[/wt][@session].
cx_target_unit_str() {
  printf '%s' "$CX_T_PROJECT"
  [ -n "$CX_T_WORKTREE" ] && printf '/%s' "$CX_T_WORKTREE"
  [ -n "$CX_T_SESSION" ] && printf '@%s' "$CX_T_SESSION"
  return 0
}
