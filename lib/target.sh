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

# cx_agent_version_ok HOST MIN FEATURE [VER] — the agent is new enough, or say so.
#
# Only called when the caller actually needs something new, so the common path
# pays nothing. Without it the failure is "cx-agent: unknown option:
# --worktree", which does not tell anyone to re-provision.
#
# Pass VER when you already have it: every caller here has just run `version`
# or `doctor` for its own reasons, and a second round trip per command is the
# difference between a driver polling six sessions in one second and six.
cx_agent_version_ok() {
  local host="$1" min="$2" feature="$3" ver="${4:-}"
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
  cx_agent_version_ok "$1" 0.2.0 "worktrees and named sessions" "${2:-}"
}

cx_agent_observe_ok() {
  cx_agent_version_ok "$1" 0.3.0 "observing and steering sessions" "${2:-}"
}

cx_agent_goals_ok() {
  cx_agent_version_ok "$1" 0.3.0 "goals" "${2:-}"
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
