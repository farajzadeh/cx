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

# cx_cache_state HOST — what the last contact said: up, down, or unknown.
#
# Read from the files alone, with no TTL and no side effects: this answers
# "how did it go last time", for `cx host ls`, and must never connect. The
# down mark outranks a listing because a listing outlives the failure after
# it — a server that answered yesterday and not an hour ago is down.
#
# It is a report, not a probe. An expired mark is usually removed on the way
# to a fresh fetch, which leaves a new mark or a new listing behind; but
# cx_cache_is_down also drops it when only checking (`cx cache status`,
# `cx bar`), and then the older listing speaks again. `cx ls -r` settles it.
cx_cache_state() {
  if [ -f "$(_cc_down "$1")" ]; then
    printf 'down'
  elif [ -s "$(_cc_list "$1")" ]; then
    printf 'up'
  else
    printf 'unknown'
  fi
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

# cx_cache_write_targets — flatten cached listings into completable targets.
#
# Emits host:project and, for every worktree, host:project/worktree — the two
# forms a command actually takes. Session labels are deliberately absent: they
# live only in tmux, and reading them would mean touching the network.
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
    # `.worktrees[]?` rather than `.worktrees[]`: a listing cached by an older
    # agent has no such field, and this must not start emitting nothing.
    out="$out$(jq -r --arg h "$host" '
      .projects[]?
      | . as $p
      | "\($h):\($p.name)", ($p.worktrees[]? | "\($h):\($p.name)/\(.name)")' \
      "$f" 2>/dev/null)
"
  done

  printf '%s' "$out" | grep -v '^$' | sort -u | cx_write_atomic "$d/targets" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Session states
# ---------------------------------------------------------------------------
#
# `cx bar --window` answers "what is this tmux tab's session doing". It runs
# once per window on every status redraw — nine windows is nine invocations
# every interval — so it must do NO network work at all, the same rule shell
# completion follows and for the same reason: a status line that blocks is
# worse than a slightly old one.
#
# So it reads this file, which any observe fan-out refreshes as a side effect.
# One line per session:
#
#   host:target<TAB>state
#
# Disposable like everything else here. Delete it and tabs lose their icons
# until the next refresh; nothing else changes.

cx_state_file() { printf '%s/state' "$(cx_cache_dir)"; }

# cx_state_write — rows on stdin, host / target / state in the first three
# columns. Anything after them is ignored, so both cx bar's rows and cx peek's
# wider display rows can be piped in unchanged.
#
# Writes the WHOLE picture or nothing: a caller that looked at one host only
# would otherwise erase every other host's tabs.
cx_state_write() {
  cx_cache_init
  awk -F'\t' 'NF >= 3 && $2 != "" { printf "%s:%s\t%s\n", $1, $2, $3 }' |
    cx_write_atomic "$(cx_state_file)" 2>/dev/null || true
}

# cx_state_read TARGET — the cached state for TARGET, or nothing.
#
# TARGET is host:project[/worktree][@label], or the unqualified form when it is
# unambiguous — resolving a bare name properly means asking the servers, which
# is exactly what this function exists not to do.
#
# Returns 1 for every "cannot say": no file, too old, no such session. The
# caller renders that as no icon rather than as a state, because a tab that
# confidently shows `idle` from a ten-minute-old file is worse than a tab that
# shows nothing.
cx_state_read() {
  local f age ttl
  f=$(cx_state_file)
  [ -s "$f" ] || return 1
  ttl="${CX_STATE_TTL:-180}"
  age=$(cx_age "$f" 2>/dev/null || printf 99999)
  [ "${age:-99999}" -lt "$ttl" ] || return 1

  awk -F'\t' -v t="$1" '
    { bare = $1; sub(/^[^:]*:/, "", bare) }
    $1 == t || bare == t { print $2; found = 1; exit }
    END { exit !found }
  ' "$f"
}

# cx_state_rows — every cached "host:target TAB state" line, or nothing when
# the cache is missing or older than CX_STATE_TTL. For callers that need the
# whole picture rather than one session: `cx jump` choosing where to go.
cx_state_rows() {
  local f age ttl
  f=$(cx_state_file)
  [ -s "$f" ] || return 1
  ttl="${CX_STATE_TTL:-180}"
  age=$(cx_age "$f" 2>/dev/null || printf 99999)
  [ "${age:-99999}" -lt "$ttl" ] || return 1
  cat "$f"
}

# cx_state_seed TARGET STATE — put TARGET in the state cache if it is not there.
#
# For a session that has just been opened: its tab should show something now,
# not after the next status-line refresh. Two restraints keep a seed from
# becoming a lie:
#
#   * It never replaces a row. An observation always beats a guess, so a
#     session the cache already knows keeps what was seen.
#   * It keeps the file's age. The age is what says how old the OTHER rows
#     are, and a seed must not make a ten-minute-old picture look fresh —
#     touching the file would have done exactly that for every tab at once.
cx_state_seed() {
  local target="$1" state="$2" f tmp
  [ -n "$target" ] && [ -n "$state" ] || return 0
  cx_cache_init
  f=$(cx_state_file)
  if [ -s "$f" ] && awk -F'\t' -v t="$target" '$1 == t { found = 1 } END { exit !found }' "$f"; then
    return 0
  fi
  tmp="$f.seed.$$"
  {
    [ -f "$f" ] && cat "$f"
    printf '%s\t%s\n' "$target" "$state"
  } >"$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 0
  }
  if [ -f "$f" ]; then
    touch -r "$f" "$tmp" 2>/dev/null || true
  fi
  mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# Goal names
# ---------------------------------------------------------------------------
#
# For shell completion only: `cx goal show <TAB>` has no other local source,
# and completion does no network work. One line per goal:
#
#   host<TAB>name<TAB>state
#
# Rewritten per host by every unfiltered `cx goal ls`, and kept roughly
# current by `goal new` and `goal rm` in between. Like the targets file it may
# be stale — a wrong name costs one useless tab, never a wrong answer from cx,
# because nothing but completion reads it.

cx_goals_file() { printf '%s/goals' "$(cx_cache_dir)"; }

# cx_goals_write HOST — "name<TAB>state" rows on stdin replace HOST's rows.
# The temp-and-rename in cx_write_atomic is what makes reading the old file
# in the same pipeline safe.
cx_goals_write() {
  local f rows
  f=$(cx_goals_file)
  rows=$(awk -F'\t' -v h="$1" '$1 != "" { printf "%s\t%s\t%s\n", h, $1, $2 }')
  cx_cache_init
  {
    [ -f "$f" ] && awk -F'\t' -v h="$1" '$1 != h' "$f"
    [ -n "$rows" ] && printf '%s\n' "$rows"
  } | cx_write_atomic "$f" 2>/dev/null || true
  return 0
}

# cx_goals_add HOST NAME / cx_goals_drop HOST NAME — one goal made or removed.
cx_goals_add() {
  cx_goals_drop "$1" "$2"
  cx_cache_init
  printf '%s\t%s\tactive\n' "$1" "$2" >>"$(cx_goals_file)" 2>/dev/null || true
  return 0
}

cx_goals_drop() {
  local f
  f=$(cx_goals_file)
  [ -f "$f" ] || return 0
  awk -F'\t' -v h="$1" -v n="$2" '!($1 == h && $2 == n)' "$f" |
    cx_write_atomic "$f" 2>/dev/null || true
  return 0
}
