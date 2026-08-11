#!/usr/bin/env bash
# lib/target.sh — resolving `host:project` targets.
#
# Resolution order:
#   1. explicit          web1:api
#   2. CX_DEFAULT_HOST   api          (when configured)
#   3. unique match      api          (searched across every host)
#
# Step 3 is the convenience that makes bare names usable day to day, and also
# the one that can be wrong. When a name exists on more than one server we
# refuse and list the candidates rather than guessing — silently opening the
# wrong server's project is a far worse outcome than one extra keystroke.
#
# Sets CX_T_HOST and CX_T_PROJECT. Returns:
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

# cx_target_split TARGET — populate CX_T_HOST / CX_T_PROJECT syntactically.
# No network access; used where the project need not exist yet (cx new).
cx_target_split() {
  local t="$1"
  CX_T_HOST=""
  CX_T_PROJECT=""

  case "$t" in
    *:*)
      CX_T_HOST="${t%%:*}"
      CX_T_PROJECT="${t#*:}"
      ;;
    *)
      CX_T_PROJECT="$t"
      CX_T_HOST="${CX_DEFAULT_HOST:-}"
      ;;
  esac

  [ -n "$CX_T_PROJECT" ] || return 3
  return 0
}

# cx_target_resolve TARGET — resolve fully, consulting servers if needed.
cx_target_resolve() {
  local t="${1:-}"
  [ -n "$t" ] || {
    err "no target given"
    hint "usage: cx <command> <host>:<project>   (or just <project>)"
    return 3
  }

  cx_target_split "$t" || {
    err "invalid target: $t"
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

# cx_target_str — "host:project" for messages.
cx_target_str() {
  printf '%s:%s' "$CX_T_HOST" "$CX_T_PROJECT"
}
