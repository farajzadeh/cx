#!/usr/bin/env bash
# lib/compat.sh — portability shims.
#
# TARGET: bash 3.2 (the version macOS ships) on both GNU and BSD userland.
# Every function here exists because the obvious approach breaks on one of them.
#
# Forbidden throughout the codebase — CI greps for these:
#   declare -A        bash 4
#   mapfile/readarray bash 4
#   ${var^^} ${var,,} bash 4
#   globstar / **     bash 4
#   wait -n           bash 4.3
#   flock             Linux only
#   sed -i            incompatible syntax GNU vs BSD
#   grep -P           not in BSD grep
#   sort -V           not in older BSD sort
#   timeout           GNU coreutils only
#   realpath          missing on older macOS
#
# Also note: under `set -u`, bash 3.2 treats an empty array expansion as an
# unbound variable. Always expand arrays as: "${arr[@]+"${arr[@]}"}"

# Guard against double-sourcing.
[ -n "${_CX_COMPAT_LOADED:-}" ] && return 0
_CX_COMPAT_LOADED=1

# ---------------------------------------------------------------------------
# Feature detection (runs once at source time)
# ---------------------------------------------------------------------------

# stat(1) is the big divergence: GNU uses -c with % format, BSD uses -f.
if stat -c %Y . >/dev/null 2>&1; then # portable-ok: this IS the probe
  _CX_STAT=gnu
elif stat -f %m . >/dev/null 2>&1; then
  _CX_STAT=bsd
else
  _CX_STAT=none
fi

# ---------------------------------------------------------------------------
# Time
# ---------------------------------------------------------------------------

# cx_now — current time as epoch seconds.
cx_now() {
  date +%s
}

# cx_iso8601 — UTC timestamp. This format string is portable across GNU/BSD.
cx_iso8601() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# cx_mtime FILE — modification time as epoch seconds, or empty if unavailable.
#
# Used for cache freshness and for keying the host list against ~/.ssh/config,
# so a wrong answer here silently breaks caching rather than erroring.
cx_mtime() {
  [ -e "$1" ] || return 1
  case "$_CX_STAT" in
    gnu) stat -c %Y -- "$1" 2>/dev/null ;; # portable-ok: guarded by probe
    bsd) stat -f %m -- "$1" 2>/dev/null ;;
    *)
      # Last resort. `date -r FILE` works on both GNU and BSD date, but is not
      # guaranteed present, so it sits below stat rather than replacing it.
      date -r "$1" +%s 2>/dev/null
      ;;
  esac
}

# cx_age FILE — seconds since FILE was modified. Empty if the file is gone.
cx_age() {
  local m now
  m=$(cx_mtime "$1") || return 1
  [ -n "$m" ] || return 1
  now=$(cx_now)
  echo $((now - m))
}

# cx_human_age SECONDS — "12s", "4m", "3h", "2d" for display.
cx_human_age() {
  local s="$1"
  if [ "$s" -lt 60 ]; then
    echo "${s}s"
  elif [ "$s" -lt 3600 ]; then
    echo "$((s / 60))m"
  elif [ "$s" -lt 86400 ]; then
    echo "$((s / 3600))h"
  else
    echo "$((s / 86400))d"
  fi
}

# ---------------------------------------------------------------------------
# Locking
# ---------------------------------------------------------------------------
#
# flock(1) is Linux-only and flock(2) via a shell fd is awkward to make
# portable. mkdir is atomic on every POSIX filesystem including NFS, so it is
# the portable primitive. The PID file inside lets us reap locks left behind
# by a killed process.

# cx_lock_acquire LOCKDIR [STALE_SECONDS]
# Returns 0 if the lock was taken, 1 if another live process holds it.
cx_lock_acquire() {
  local dir="$1" stale="${2:-300}" pid age

  if mkdir "$dir" 2>/dev/null; then
    echo $$ >"$dir/pid" 2>/dev/null || true
    return 0
  fi

  # Someone holds it. Decide whether they are still alive.
  pid=$(cat "$dir/pid" 2>/dev/null || echo "")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 1 # genuinely held
  fi

  # No live holder. Only break the lock once it is older than STALE_SECONDS,
  # so we do not race a process that just created the dir and has not yet
  # written its pid file.
  age=$(cx_age "$dir" 2>/dev/null || echo 0)
  if [ "${age:-0}" -lt "$stale" ]; then
    return 1
  fi

  rm -rf "$dir" 2>/dev/null || true
  if mkdir "$dir" 2>/dev/null; then
    echo $$ >"$dir/pid" 2>/dev/null || true
    return 0
  fi
  return 1
}

# cx_lock_release LOCKDIR
cx_lock_release() {
  [ -n "${1:-}" ] || return 0
  rm -rf "$1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Filesystem
# ---------------------------------------------------------------------------

# cx_mktemp [TEMPLATE] — portable temp file. BSD mktemp requires a template
# with trailing X's; GNU accepts a bare -t. Supplying a full template works on
# both. Caller is responsible for cleanup.
cx_mktemp() {
  local tmpl="${1:-cx.XXXXXX}"
  mktemp "${TMPDIR:-/tmp}/$tmpl" 2>/dev/null || {
    # Ancient/absent mktemp. $RANDOM plus PID is adequate here because these
    # files live in a directory we control, not a shared /tmp namespace.
    local f="${TMPDIR:-/tmp}/${tmpl%%.*}.$$.$RANDOM"
    : >"$f" && chmod 600 "$f" && echo "$f"
  }
}

# cx_mktempdir — portable temp directory.
cx_mktempdir() {
  mktemp -d "${TMPDIR:-/tmp}/cx.XXXXXX" 2>/dev/null || {
    local d="${TMPDIR:-/tmp}/cx.$$.$RANDOM"
    mkdir -p "$d" && chmod 700 "$d" && echo "$d"
  }
}

# cx_write_atomic DEST — read stdin, write DEST atomically.
#
# This is the single most important function in this file. Every cache and
# registry write goes through it. Because the rename is atomic, a reader can
# only ever see the complete old value or the complete new one, never a
# half-written file. The temp file is created as a sibling of DEST so that the
# rename never crosses a filesystem boundary (which would silently degrade to
# a non-atomic copy).
cx_write_atomic() {
  local dest="$1" dir tmp
  dir=$(dirname "$dest")
  mkdir -p "$dir" 2>/dev/null || true
  tmp="$dir/.cx.tmp.$$.$RANDOM"
  cat >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$dest" || {
    rm -f "$tmp"
    return 1
  }
}

# cx_realpath PATH — absolute, symlink-resolved path.
# realpath(1) is absent on older macOS and readlink -f is GNU-only.
cx_realpath() {
  local p="$1" d b
  if [ -d "$p" ]; then
    (cd "$p" 2>/dev/null && pwd -P)
    return
  fi
  d=$(dirname "$p")
  b=$(basename "$p")
  d=$(cd "$d" 2>/dev/null && pwd -P) || return 1
  case "$d" in
    */) echo "$d$b" ;;
    *) echo "$d/$b" ;;
  esac
}

# cx_sanitize STRING — reduce to [A-Za-z0-9._-] so it is safe as a filename.
#
# Used for cache filenames keyed by host alias. We deliberately sanitize
# rather than hash: GNU has md5sum, BSD has md5, and neither is guaranteed —
# and a readable ~/.cache/cx/list/web1.json is far easier to debug than a
# directory full of hashes.
cx_sanitize() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# ---------------------------------------------------------------------------
# Process
# ---------------------------------------------------------------------------

# cx_bg COMMAND... — detach COMMAND from this shell entirely.
#
# setsid(1) is Linux-only. nohup plus a subshell is the portable equivalent:
# the process survives the parent exiting and holds no terminal, which matters
# because background cache refreshes must not write to the user's terminal or
# keep it open after the foreground command returns.
cx_bg() {
  (
    nohup "$@" >/dev/null 2>&1 &
  ) >/dev/null 2>&1
}

# cx_have COMMAND — is COMMAND on PATH?
cx_have() {
  command -v "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Version comparison
# ---------------------------------------------------------------------------

# cx_version_ge A B — true if version A >= version B.
#
# `sort -V` is absent from older BSD sort, so this compares dotted components
# numerically. Non-numeric suffixes (7.9p1, 3.2.57(1)-release) are trimmed at
# the first non-digit, which is the right behavior for the version gates we
# apply (bash >= 3.2, OpenSSH >= 7.3).
cx_version_ge() {
  local a="$1" b="$2" ai bi pair
  # shellcheck disable=SC2086
  set -- ${a//./ }
  local a1="${1:-0}" a2="${2:-0}" a3="${3:-0}"
  # shellcheck disable=SC2086
  set -- ${b//./ }
  local b1="${1:-0}" b2="${2:-0}" b3="${3:-0}"

  for pair in "$a1:$b1" "$a2:$b2" "$a3:$b3"; do
    ai="${pair%%:*}"
    bi="${pair##*:}"
    # Trim at the first non-digit: "57(1)-release" -> "57", "9p1" -> "9".
    ai=$(printf '%s' "$ai" | sed 's/[^0-9].*$//')
    bi=$(printf '%s' "$bi" | sed 's/[^0-9].*$//')
    ai=${ai:-0}
    bi=${bi:-0}
    if [ "$ai" -gt "$bi" ]; then return 0; fi
    if [ "$ai" -lt "$bi" ]; then return 1; fi
  done
  return 0 # equal
}

# ---------------------------------------------------------------------------
# Platform identity
# ---------------------------------------------------------------------------

# cx_os — linux | macos | bsd | windows | unknown
cx_os() {
  case "$(uname -s 2>/dev/null)" in
    Linux*) echo linux ;;
    Darwin*) echo macos ;;
    *BSD*) echo bsd ;;
    CYGWIN* | MINGW* | MSYS*) echo windows ;;
    *) echo unknown ;;
  esac
}

# cx_is_wsl — true inside Windows Subsystem for Linux.
# WSL reports Linux but needs different handling for `code --remote`.
cx_is_wsl() {
  [ -n "${WSL_DISTRO_NAME:-}" ] && return 0
  grep -qi microsoft /proc/version 2>/dev/null
}
