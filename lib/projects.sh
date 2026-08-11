#!/usr/bin/env bash
# lib/projects.sh — fetching project lists from servers.
#
# One function fetches from a single host; another fans out across all of
# them. The cache layer (lib/cache.sh) wraps these rather than replacing them,
# so `--no-cache` exercises exactly the same code path as a cache miss.

[ -n "${_CX_PROJECTS_LOADED:-}" ] && return 0
_CX_PROJECTS_LOADED=1

# shellcheck source=hosts.sh
. "$CX_HOME/lib/hosts.sh"
# shellcheck source=remote.sh
. "$CX_HOME/lib/remote.sh"

# cx_projects_fetch HOST [--git] — raw agent output for one host.
# Returns 1 on any failure; the caller decides whether that means
# "unreachable" or "agent missing".
cx_projects_fetch() {
  local host="$1"
  shift
  cx_agent "$host" list "$@" 2>/dev/null
}

# cx_projects_get HOST [--git] — one host, through the cache.
#
# Decision order, and why:
#
#   --no-cache     read straight through, write nothing. Exercises exactly the
#                  same fetch path as a miss, so it is a real bypass.
#   --git          never served from cache: the plain cache entry has no dirty
#                  field, and silently omitting a requested column is worse
#                  than the extra round trip.
#   -r/--refresh   fetch and update, clearing any unreachable mark.
#   marked down    fail immediately WITHOUT connecting. This is what stops one
#                  offline server costing a timeout on every command.
#   fresh          serve from cache.
#   stale          serve from cache, refresh in the background.
#   --stale        serve any age; only -r fetches. An offline mode.
#
# Prints the payload (with host/ok fields) on success. Returns 1 on failure.

# _cx_projects_cached HOST [--git] — answer from cache alone, or return 1.
#
# Split out of cx_projects_get so the fan-out can serve cache hits without
# forking. Kicks off a background refresh for a stale entry, exactly as the
# full path does.
_cx_projects_cached() {
  local host="$1" git_flag="${2:-}" out

  [ "${CX_NO_CACHE:-0}" = 1 ] && return 1
  [ -n "$git_flag" ] && return 1 # dirty state is never cached
  [ "${CX_REFRESH:-0}" = 1 ] && return 1

  if [ "${CX_FORCE_STALE:-0}" = 1 ]; then
    out=$(cx_cache_read "$host") || return 1
    printf '%s' "$out"
    return 0
  fi

  cx_cache_is_down "$host" && return 1
  out=$(cx_cache_read "$host") || return 1

  if ! cx_cache_fresh "$host"; then
    cx_cache_refresh_bg "$host"
  fi
  printf '%s' "$out"
  return 0
}

cx_projects_get() {
  local host="$1" git_flag="${2:-}" out

  if [ "${CX_NO_CACHE:-0}" = 1 ] || [ -n "$git_flag" ]; then
    if out=$(cx_projects_fetch "$host" $git_flag); then
      printf '%s' "$out" | jq -c --arg h "$host" '. + {host:$h, ok:true}'
      return 0
    fi
    return 1
  fi

  if [ "${CX_REFRESH:-0}" != 1 ]; then
    if [ "${CX_FORCE_STALE:-0}" = 1 ]; then
      if out=$(cx_cache_read "$host"); then
        printf '%s' "$out"
        return 0
      fi
    elif cx_cache_is_down "$host"; then
      return 1
    elif out=$(cx_cache_read "$host"); then
      if cx_cache_fresh "$host"; then
        printf '%s' "$out"
        return 0
      fi
      # Stale: answer now, refresh for next time.
      cx_cache_refresh_bg "$host"
      printf '%s' "$out"
      return 0
    fi
  fi

  if out=$(cx_projects_fetch "$host" $git_flag); then
    out=$(printf '%s' "$out" | jq -c --arg h "$host" '. + {host:$h, ok:true}')
    printf '%s' "$out" | cx_cache_write "$host"
    cx_cache_clear_down "$host"
    printf '%s' "$out"
    return 0
  fi

  cx_cache_mark_down "$host"
  return 1
}

# cx_projects_fanout [--git] — every host, concurrently.
#
# Emits one JSON object per line: the payload with a `host` field added, or an
# `error` field for hosts that could not be reached. Errors are reported
# rather than dropped so `cx ls` can show a partial view and say which servers
# are missing from it — a silently short list would look authoritative.
#
# Concurrency uses background jobs writing to per-host files, then a plain
# `wait`. `wait -n` would be tidier but is bash 4.3+, and this must run on 3.2.
cx_projects_fanout() {
  local git_flag="" hosts h tmp safe down_note
  [ "${1:-}" = "--git" ] && git_flag="--git"

  hosts=$(cx_hosts_list)
  [ -n "$hosts" ] || return 0

  tmp=$(cx_mktempdir)

  # Two phases. Anything the cache can answer is served inline — forking a
  # subshell to read a local file costs more than the read. Only hosts that
  # genuinely need the network are backgrounded, so a fully warm `cx ls` does
  # no forking at all.
  local needs_network=""
  for h in $hosts; do
    safe=$(cx_sanitize "$h")
    if out=$(_cx_projects_cached "$h" "$git_flag"); then
      printf '%s' "$out" >"$tmp/$safe.out"
    elif cx_cache_is_down "$h"; then
      # Already known unreachable and still within the TTL: do not connect.
      printf 'cached' >"$tmp/$safe.why"
    else
      needs_network="$needs_network $h"
    fi
  done

  for h in $needs_network; do
    safe=$(cx_sanitize "$h")
    (
      if out=$(cx_projects_get "$h" "$git_flag"); then
        printf '%s' "$out" >"$tmp/$safe.out"
      else
        printf 'live' >"$tmp/$safe.why"
      fi
    ) &
  done
  [ -n "$needs_network" ] && wait

  for h in $hosts; do
    safe=$(cx_sanitize "$h")
    if [ -s "$tmp/$safe.out" ] && jq -e . "$tmp/$safe.out" >/dev/null 2>&1; then
      cat "$tmp/$safe.out"
      printf '\n'
    else
      down_note="unreachable or agent not installed"
      if [ -f "$tmp/$safe.why" ] && [ "$(cat "$tmp/$safe.why")" = cached ]; then
        down_note="unreachable (remembered; retrying in <${CX_UNREACHABLE_TTL:-60}s)"
      fi
      jq -nc --arg host "$h" --arg e "$down_note" '{host:$host, ok:false, error:$e}'
    fi
  done

  rm -rf "$tmp"
}

# cx_projects_flat [--git] — one JSON object per project, with its host.
# The shape most consumers want: resolution, listing, and completion.
# shellcheck disable=SC2120  # --git is optional; callers may pass it
cx_projects_flat() {
  cx_projects_fanout "$@" |
    jq -c 'select(.ok) as $h | .projects[]? | . + {host: $h.host}' 2>/dev/null
}

# cx_project_find NAME — every project with this name, across all hosts.
# Emits "host<TAB>name" lines; zero lines means not found, more than one
# means ambiguous.
cx_project_find() {
  local name="$1"
  cx_projects_flat | jq -r --arg n "$name" 'select(.name == $n) | "\(.host)\t\(.name)"'
}
