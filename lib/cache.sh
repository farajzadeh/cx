#!/usr/bin/env bash
# lib/cache.sh — read-through cache for server project listings.
#
# `cx ls` is the most-run command, and uncached it costs an SSH round trip per
# server. Worse, one unreachable server stalls the whole fan-out — so caching
# here is a correctness feature as much as a speed one.
#
# THREE PROPERTIES MAKE IT TRUSTWORTHY RATHER THAN ANNOYING:
#
#   1. Mutations invalidate synchronously. `cx new` drops its host's entry
#      before returning, so the next `cx ls` shows the new project without -r.
#      A cache that is wrong exactly when you just changed something is worse
#      than no cache at all.
#
#   2. Stale-while-revalidate. Stale data prints immediately and one
#      background refresh is forked, so a miss is never a visible wait.
#
#   3. Dead hosts are contained. A failed connection is remembered, so an
#      offline server costs one ConnectTimeout rather than one per command.
#
# THE CACHE IS NEVER A SOURCE OF TRUTH. `rm -rf ~/.cache/cx` at any moment
# must change speed only. Nothing is stored here that cannot be re-fetched.

[ -n "${_CX_CACHE_LOADED:-}" ] && return 0
_CX_CACHE_LOADED=1

cx_cache_dir() { printf '%s' "${CX_CACHE_DIR:-$HOME/.cache/cx}"; }
_cc_list() { printf '%s/list/%s.json' "$(cx_cache_dir)" "$(cx_sanitize "$1")"; }
_cc_down() { printf '%s/down/%s' "$(cx_cache_dir)" "$(cx_sanitize "$1")"; }
_cc_lock() { printf '%s/lock/%s' "$(cx_cache_dir)" "$(cx_sanitize "$1")"; }

cx_cache_init() {
  local d
  d=$(cx_cache_dir)
  mkdir -p "$d/list" "$d/down" "$d/lock" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Entries
# ---------------------------------------------------------------------------

# cx_cache_age HOST — seconds since the entry was written, or empty if none.
cx_cache_age() {
  local f
  f=$(_cc_list "$1")
  [ -f "$f" ] || return 1
  cx_age "$f"
}

# cx_cache_read HOST — print the cached payload. Returns 1 if absent or empty.
#
# Deliberately does NOT validate the JSON: every consumer parses it anyway and
# reports a bad payload as an unreachable host, so a `jq -e` here would be a
# second parse of the same bytes on the hot path of the most-run command.
# Atomic writes mean a truncated file is not a case we need to defend against.
cx_cache_read() {
  local f
  f=$(_cc_list "$1")
  [ -s "$f" ] || return 1
  cat "$f"
}

# cx_cache_write HOST < payload
cx_cache_write() {
  cx_cache_init
  cx_write_atomic "$(_cc_list "$1")"
  # Completion reads this file and must never touch the network, so it is
  # refreshed as a side effect of any successful fetch.
  cx_cache_write_targets 2>/dev/null || true
}

# cx_cache_invalidate [HOST] — drop cached data. No host means all hosts.
#
# Called synchronously by every command that changes server state.
cx_cache_invalidate() {
  local d
  d=$(cx_cache_dir)
  if [ -n "${1:-}" ]; then
    rm -f "$(_cc_list "$1")" "$(_cc_down "$1")" 2>/dev/null || true
  else
    rm -rf "$d/list" "$d/down" 2>/dev/null || true
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Negative cache
# ---------------------------------------------------------------------------
#
# Without this, a powered-off server costs CX_CONNECT_TIMEOUT on every single
# command. With it, that cost is paid once per CX_UNREACHABLE_TTL.

cx_cache_mark_down() {
  cx_cache_init
  printf '%s\n' "${2:-unreachable}" >"$(_cc_down "$1")" 2>/dev/null || true
}

cx_cache_clear_down() {
  rm -f "$(_cc_down "$1")" 2>/dev/null || true
}

# cx_cache_is_down HOST — true when marked down and the mark has not expired.
cx_cache_is_down() {
  local f age ttl
  f=$(_cc_down "$1")
  [ -f "$f" ] || return 1
  ttl="${CX_UNREACHABLE_TTL:-60}"
  age=$(cx_age "$f" 2>/dev/null || printf 99999)
  if [ "${age:-99999}" -ge "$ttl" ]; then
    rm -f "$f" 2>/dev/null || true
    return 1
  fi
  return 0
}

cx_cache_down_age() {
  cx_age "$(_cc_down "$1")" 2>/dev/null || printf ''
}

# ---------------------------------------------------------------------------
# Freshness
# ---------------------------------------------------------------------------

# cx_cache_fresh HOST — is the entry within TTL?
cx_cache_fresh() {
  local age ttl
  ttl="${CX_CACHE_TTL:-30}"
  [ "$ttl" -gt 0 ] || return 1
  age=$(cx_cache_age "$1") || return 1
  [ "${age:-99999}" -lt "$ttl" ]
}

# ---------------------------------------------------------------------------
# Background refresh
# ---------------------------------------------------------------------------

# cx_cache_refresh_bg HOST — refresh without blocking the caller.
#
# The lock makes the refresh idempotent under concurrency: five rapid `cx ls`
# calls fork one refresh, not five. A stale lock is reaped by cx_lock_acquire.
cx_cache_refresh_bg() {
  local host="$1" lock
  cx_cache_init
  lock=$(_cc_lock "$host")

  cx_lock_acquire "$lock" 120 || return 0 # someone else is already on it

  # The child releases the lock; releasing here would defeat the guard.
  cx_bg env \
    CX_HOME="$CX_HOME" \
    CX_CACHE_DIR="$(cx_cache_dir)" \
    CX_CONFIG_DIR="${CX_CONFIG_DIR:-}" \
    CX_CONFIG_FILE="${CX_CONFIG_FILE:-}" \
    CX_SSHD_DIR="${CX_SSHD_DIR:-}" \
    CX_SSH_CONFIG="${CX_SSH_CONFIG:-}" \
    CX_CACHE_LOCK_HELD=1 \
    bash "$CX_HOME/bin/cx" cache refresh "$host"
}

# ---------------------------------------------------------------------------
# Completion targets
# ---------------------------------------------------------------------------

# cx_cache_write_targets — flatten cached listings into host:project lines.
#
# Shell completion reads this and performs NO network work, not even in the
# background. Tab must never hang; it is the one place where stale data
# unconditionally beats fresh.
cx_cache_write_targets() {
  local d f host out=""
  d=$(cx_cache_dir)
  [ -d "$d/list" ] || return 0

  for f in "$d"/list/*.json; do
    [ -e "$f" ] || continue
    host=$(jq -r '.host // empty' "$f" 2>/dev/null)
    if [ -z "$host" ]; then
      host=$(basename "$f" .json)
    fi
    out="$out$(jq -r --arg h "$host" '.projects[]?.name | "\($h):\(.)"' "$f" 2>/dev/null)
"
  done

  printf '%s' "$out" | grep -v '^$' | sort -u | cx_write_atomic "$d/targets" 2>/dev/null || true
}
