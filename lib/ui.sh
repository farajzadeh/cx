#!/usr/bin/env bash
# lib/ui.sh — terminal output: color, messages, tables.
#
# Everything here is TTY-aware. When stdout is a pipe, color is dropped so
# `cx ls | grep` works on the text a user actually sees rather than on escape
# sequences. NO_COLOR (https://no-color.org) is honored.

[ -n "${_CX_UI_LOADED:-}" ] && return 0
_CX_UI_LOADED=1

# cx_ui_init — (re)compute the color variables.
#
# Called once at source time and again after global flags are parsed. Without
# the second call, --no-color is a no-op: the variables are already set by the
# time the flag is read. Also honours NO_COLOR (https://no-color.org) and
# drops color whenever stdout is not a terminal, so `cx ls | grep` matches the
# text a user sees rather than escape sequences.
cx_ui_init() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${CX_NO_COLOR:-0}" != 1 ]; then
    C_RESET=$(printf '\033[0m')
    C_BOLD=$(printf '\033[1m')
    C_DIM=$(printf '\033[2m')
    C_RED=$(printf '\033[31m')
    C_GREEN=$(printf '\033[32m')
    C_YELLOW=$(printf '\033[33m')
    C_CYAN=$(printf '\033[36m')
  else
    C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_CYAN=''
  fi
}

cx_ui_init

# Informational output goes to stdout; diagnostics to stderr. This is what
# lets `cx ls --json | jq` work while errors still reach the terminal.
say() { printf '%s\n' "$*"; }
hdr() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }
note() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

err() { printf '%scx:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
warn() { printf '%scx:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
info() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; }

# die MESSAGE [EXIT_CODE]
die() {
  err "$1"
  exit "${2:-1}"
}

# hint MESSAGE — a suggested next step after an error. Always to stderr, so it
# never contaminates parsable output.
hint() {
  printf '    %s→ %s%s\n' "$C_CYAN" "$*" "$C_RESET" >&2
}

ok_mark() { printf '%s✓%s' "$C_GREEN" "$C_RESET"; }
bad_mark() { printf '%s✗%s' "$C_RED" "$C_RESET"; }
dash_mark() { printf '%s-%s' "$C_YELLOW" "$C_RESET"; }

# ---------------------------------------------------------------------------
# Tables
# ---------------------------------------------------------------------------
#
# Rows arrive as tab-separated lines on stdin. Column widths are computed from
# the data so output stays aligned regardless of content length.
#
#   printf 'HOST\tPROJECT\n' | cx_table
#
# Colored cells would break width computation (escape sequences count as
# characters), so callers colorize only after the table is laid out, or use
# cx_table_plain for data that is already styled.

# cx_table [--no-header] — align tab-separated stdin into columns.
cx_table() {
  local no_header=0
  [ "${1:-}" = "--no-header" ] && no_header=1

  awk -v bold="$C_BOLD" -v reset="$C_RESET" -v dim="$C_DIM" -v nh="$no_header" '
    BEGIN { FS = "\t"; nrows = 0; ncols = 0 }
    {
      rows[nrows] = $0
      for (i = 1; i <= NF; i++) {
        cell[nrows, i] = $i
        # Ignore ANSI escapes when measuring width.
        plain = $i
        gsub(/\033\[[0-9;]*m/, "", plain)
        w = length(plain)
        if (w > width[i]) width[i] = w
        if (i > ncols) ncols = i
      }
      nfields[nrows] = NF
      nrows++
    }
    END {
      for (r = 0; r < nrows; r++) {
        line = ""
        for (i = 1; i <= nfields[r]; i++) {
          c = cell[r, i]
          plain = c
          gsub(/\033\[[0-9;]*m/, "", plain)
          pad = width[i] - length(plain)
          if (i < nfields[r]) {
            sp = ""
            for (j = 0; j < pad + 2; j++) sp = sp " "
            line = line c sp
          } else {
            line = line c
          }
        }
        if (r == 0 && nh == 0) print bold line reset
        else print line
      }
    }
  '
}

# cx_confirm PROMPT — yes/no. Declines when there is no terminal, so a
# non-interactive caller never hangs or silently gets a "yes".
cx_confirm() {
  local prompt="$1" reply=""
  [ "${CX_ASSUME_YES:-0}" = 1 ] && return 0
  if [ ! -t 0 ]; then
    return 1
  fi
  printf '%s [y/N] ' "$prompt"
  read -r reply || return 1
  case "$reply" in y | Y | yes | YES) return 0 ;; *) return 1 ;; esac
}

# cx_spinner_start MESSAGE / cx_spinner_stop — progress for slow fan-outs.
# Writes to stderr and only when attached to a terminal, so piped output is
# never polluted.
_CX_SPINNER_MSG=""
cx_spinner_start() {
  _CX_SPINNER_MSG="$1"
  [ -t 2 ] || return 0
  printf '%s%s...%s' "$C_DIM" "$1" "$C_RESET" >&2
}
cx_spinner_stop() {
  [ -t 2 ] || return 0
  [ -n "$_CX_SPINNER_MSG" ] || return 0
  # Erase the line rather than newline over it, so the real output starts clean.
  printf '\r\033[K' >&2
  _CX_SPINNER_MSG=""
}
