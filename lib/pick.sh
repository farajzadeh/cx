#!/usr/bin/env bash
# lib/pick.sh — choosing a target interactively.
#
# One primitive (cx_pick) and a few candidate builders on top of it. fzf when
# it is installed, a built-in numbered menu otherwise: fzf is the better
# experience, but cx runs on machines where nothing extra is installed, and a
# picker that only exists with fzf would make "no target given" behave
# differently from one laptop to the next.
#
# A picker is a prompt, so it follows the same rule every prompt does: only
# when a human is there to answer. cx_pick_ok is that rule, written once.
# Everything else — a script, a pipe, --json, -y — keeps getting exit 3 for a
# missing target, exactly as before this file existed.
#
# Candidates are lines of "value<TAB>col<TAB>col...". The value is what the
# caller gets back and is never shown on its own; the columns are aligned
# into one display string, so fzf and the built-in menu show the same thing.

[ -n "${_CX_PICK_LOADED:-}" ] && return 0
_CX_PICK_LOADED=1

# Exit status for "the human backed out". 130 is what a shell reports for
# Ctrl-C, and what fzf itself returns for Esc — a cancel is an interrupt, not
# a usage error, and a caller must be able to tell the two apart.
CX_PICK_CANCEL=130

# cx_pick_ok — is there a human to ask?
#
# Both ends must be a terminal: stdin because that is where the answer comes
# from, stderr because that is where the menu goes (stdout carries the chosen
# value back to the caller's command substitution). CX_PICKER=none turns the
# whole thing off for someone who wants the old behaviour back.
cx_pick_ok() {
  _cx_pick_tty || return 1
  [ "${CX_JSON:-0}" != 1 ] || return 1
  [ "${CX_ASSUME_YES:-0}" != 1 ] || return 1
  [ "${CX_PICKER:-auto}" != none ] || return 1
  return 0
}

# _cx_pick_tty — its own function so a test, which has no terminal, can say
# that it does.
_cx_pick_tty() { [ -t 0 ] && [ -t 2 ]; }

# _cx_pick_backend — fzf or builtin. CX_PICKER=fzf|builtin forces one.
_cx_pick_backend() {
  case "${CX_PICKER:-auto}" in
    builtin) printf builtin ;;
    fzf) printf fzf ;;
    *) if cx_have fzf; then printf fzf; else printf builtin; fi ;;
  esac
}

# _cx_pick_align — "value<TAB>c1<TAB>c2..." → "value<TAB>c1  c2...", padded.
#
# Two passes over the data in awk (widths first, then output) rather than
# cx_table, because the value column must survive untouched for the caller
# and must not be counted towards any width.
_cx_pick_align() {
  awk -F'\t' '
    { rows[NR] = $0
      for (i = 2; i <= NF; i++) if (length($i) > w[i]) w[i] = length($i)
      if (NF > nf) nf = NF }
    END {
      for (r = 1; r <= NR; r++) {
        n = split(rows[r], f, "\t")
        line = ""
        for (i = 2; i <= n; i++) {
          cell = f[i]
          if (i < n) cell = sprintf("%-" w[i] "s  ", cell)
          line = line cell
        }
        sub(/ +$/, "", line)
        printf "%s\t%s\n", f[1], line
      }
    }'
}

# cx_pick [--prompt P] [--header H] [--preview CMD] — choose one line.
#
# Candidates on stdin, the chosen VALUE on stdout. Returns CX_PICK_CANCEL when
# the human backs out, and 2 when there was nothing to choose from — the same
# "not found" a mistyped target gets.
#
# --preview is an fzf preview command; {1} in it is the candidate's value.
# The built-in menu has nowhere to show one and ignores it.
cx_pick() {
  local prompt="select" header="" preview="" rows
  while [ $# -gt 0 ]; do
    case "$1" in
      --prompt)
        prompt="$2"; shift
        ;;
      --header)
        header="$2"; shift
        ;;
      --preview)
        preview="$2"; shift
        ;;
    esac
    shift
  done

  rows=$(grep -v '^[[:space:]]*$' | _cx_pick_align)
  [ -n "$rows" ] || return 2

  case "$(_cx_pick_backend)" in
    fzf) _cx_pick_fzf "$prompt" "$header" "$preview" "$rows" ;;
    *) _cx_pick_builtin "$prompt" "$header" "$rows" ;;
  esac
}

_cx_pick_fzf() {
  local prompt="$1" header="$2" preview="$3" rows="$4" out rc=0
  set -- --delimiter="$(printf '\t')" --with-nth=2.. --height=~50% --reverse \
    --no-multi --select-1 --exit-0 --prompt="$prompt> "
  [ -n "$header" ] && set -- "$@" --header="$header"
  [ -n "$preview" ] && set -- "$@" --preview="$preview" --preview-window=right,50%,wrap
  out=$(printf '%s\n' "$rows" | fzf "$@") || rc=$?
  # fzf: 1 = no match, 130 = Esc/Ctrl-C. Both mean nothing was chosen.
  [ "$rc" = 0 ] && [ -n "$out" ] || return "$CX_PICK_CANCEL"
  printf '%s\n' "${out%%	*}"
}

# _cx_pick_builtin PROMPT HEADER ROWS — a numbered menu with a filter.
#
# Type a number to choose, text to narrow the list (every word must appear,
# case-insensitively), an empty line to clear the filter, q to cancel. A
# filter that leaves exactly one row chooses it — typing a name is the
# commonest way to say which one.
#
# Reads the answer from /dev/tty, not stdin: stdin is where the candidates
# came from. CX_PICK_TTY_IN / CX_PICK_TTY_OUT exist for the tests, which have
# no terminal; the input is opened once on fd 3 so successive reads advance
# through it rather than each re-reading its first line.
_cx_pick_builtin() {
  local prompt="$1" header="$2" rows="$3" filter="" shown n answer max=20 total pick
  local tty_in="${CX_PICK_TTY_IN:-/dev/tty}" tty="${CX_PICK_TTY_OUT:-/dev/tty}"

  # When there is only one candidate, there is no question to ask.
  if [ "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" = 1 ]; then
    printf '%s\n' "${rows%%	*}"
    return 0
  fi

  # Braces, so the 2>/dev/null is temporary: on a bare exec it would be
  # permanent, and every later error message would vanish.
  { exec 3<"$tty_in"; } 2>/dev/null || return "$CX_PICK_CANCEL"
  while :; do
    shown=$(printf '%s\n' "$rows" | awk -F'\t' -v q="$filter" '
      BEGIN { n = split(tolower(q), words, /[ \t]+/) }
      { hay = tolower($2); ok = 1
        for (i = 1; i <= n; i++) if (words[i] != "" && index(hay, words[i]) == 0) ok = 0
        if (ok) print }')
    total=0
    [ -n "$shown" ] && total=$(printf '%s\n' "$shown" | wc -l | tr -d ' ')

    if [ -n "$filter" ] && [ "$total" = 1 ]; then
      exec 3<&-
      printf '%s\n' "${shown%%	*}"
      return 0
    fi

    {
      [ -n "$header" ] && printf '%s%s%s\n' "$C_DIM" "$header" "$C_RESET"
      if [ "$total" = 0 ]; then
        printf '  %sno match for "%s"%s\n' "$C_YELLOW" "$filter" "$C_RESET"
      else
        printf '%s\n' "$shown" | awk -F'\t' -v max="$max" \
          'NR <= max { printf "  %3d) %s\n", NR, $2 }'
        [ "$total" -gt "$max" ] &&
          printf '  %s… %d more — type to narrow%s\n' "$C_DIM" "$((total - max))" "$C_RESET"
      fi
      if [ -n "$filter" ]; then
        printf '%s%s [%s]>%s ' "$C_BOLD" "$prompt" "$filter" "$C_RESET"
      else
        printf '%s%s (number, text to filter, q to quit)>%s ' "$C_BOLD" "$prompt" "$C_RESET"
      fi
    } >"$tty"

    answer=""
    IFS= read -r answer <&3 || {
      exec 3<&-
      return "$CX_PICK_CANCEL"
    }
    case "$answer" in
      q | Q)
        exec 3<&-
        return "$CX_PICK_CANCEL"
        ;;
      '') filter="" ;;
      *[!0-9]*) filter="$answer" ;;
      *)
        n="$answer"
        if [ "$n" -ge 1 ] && [ "$n" -le "$total" ] && [ "$n" -le "$max" ]; then
          pick=$(printf '%s\n' "$shown" | sed -n "${n}p")
          exec 3<&-
          printf '%s\n' "${pick%%	*}"
          return 0
        fi
        printf '  %sno row %s%s\n' "$C_YELLOW" "$answer" "$C_RESET" >"$tty"
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Candidates
# ---------------------------------------------------------------------------

# cx_pick_host [PROMPT] — choose a configured server.
cx_pick_host() {
  local h
  cx_hosts_list | while IFS= read -r h; do
    [ -n "$h" ] && printf '%s\t%s\n' "$h" "$h"
  done | cx_pick --prompt "${1:-host}"
}

# cx_pick_candidates KIND [HOST] — candidate rows, without asking.
#
#   project   host:project only
#   unit      projects and their worktrees — anything `cx open` takes
#
# Built from the same listing `cx ls` shows, through the same cache, so a
# warm picker costs what a warm `cx ls` does. Split from cx_pick_target so a
# test can check what would be offered without a terminal.
cx_pick_candidates() {
  local kind="$1" only="${2:-}"
  # shellcheck source=projects.sh
  . "$CX_HOME/lib/projects.sh"
  cx_projects_flat | jq -r --arg kind "$kind" --arg only "$only" '
    select($only == "" or .host == $only)
    | . as $p
    | def live: if (.tmux_count // 0) > 1 then "●\(.tmux_count)"
                elif .tmux_live then "●" else "" end;
      ([ "\($p.host):\($p.name)", "\($p.host):\($p.name)",
         ($p.branch // "—"), ($p | live) ] | @tsv),
      (if $kind == "unit" then
         ($p.worktrees[]?
          | [ "\($p.host):\($p.name)/\(.name)", "\($p.host):\($p.name)/\(.name)",
              (.branch // "—"), (. | live) ] | @tsv)
       else empty end)'
}

# cx_pick_target KIND [PROMPT] [HOST] — choose a target interactively.
#
# Prints host:project[/worktree]. Returns CX_PICK_CANCEL on cancel and 2 when
# there is nothing to choose from.
cx_pick_target() {
  local kind="$1" prompt="${2:-target}" only="${3:-}" rows
  cx_spinner_start "querying servers" 2>/dev/null || true
  rows=$(cx_pick_candidates "$kind" "$only")
  cx_spinner_stop 2>/dev/null || true
  [ -n "$rows" ] || {
    err "no projects to choose from"
    hint "create one with: cx new <host>:<name>"
    return 2
  }
  printf '%s\n' "$rows" | cx_pick --prompt "$prompt"
}

# ---------------------------------------------------------------------------
# Questions
# ---------------------------------------------------------------------------
#
# cx_ask_line and cx_ask_yn — a line of text, or a yes or no, from the human.
# The same rule as the picker: callers ask only when cx_pick_ok says someone
# is there, and a script keeps getting exit 3 for whatever it left out.
#
# The answer is left in CX_ASK_REPLY rather than printed, so the functions run
# in the caller's shell instead of a command substitution's subshell. That is
# what lets the input stay open on fd 4 from one question to the next: a
# terminal does not care, but CX_PICK_TTY_IN — the tests' stand-in for one —
# is a plain file, and reopening it for every question would answer each of
# them with its first line.
#
# fd 4, not the picker's 3: the picker closes 3 when it returns, and a
# question asked after a pick must not find its input gone.

CX_ASK_REPLY=""
_CX_ASK_IN=""

_cx_ask_open() {
  local tty_in="${CX_PICK_TTY_IN:-/dev/tty}"
  [ "$_CX_ASK_IN" = "$tty_in" ] && return 0
  cx_ask_reset
  # Braces, so the 2>/dev/null does not outlive the exec (see the picker).
  { exec 4<"$tty_in"; } 2>/dev/null || return 1
  _CX_ASK_IN="$tty_in"
}

# cx_ask_reset — let go of the input. Called before cx hands the terminal to
# something else, and by a test that has just rewritten its answers.
cx_ask_reset() {
  if [ -n "$_CX_ASK_IN" ]; then
    exec 4<&-
    _CX_ASK_IN=""
  fi
  return 0
}

# _cx_ask_read — one line from the terminal into CX_ASK_REPLY, trimmed.
# A last line with no newline still counts; only a true end of input fails.
_cx_ask_read() {
  local line=""
  IFS= read -r line <&4 || [ -n "$line" ] || return 1
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  CX_ASK_REPLY="$line"
}

# cx_ask_line PROMPT [DEFAULT] — ask for a line of text.
#
# An empty answer takes DEFAULT, which is shown in brackets. Returns
# CX_PICK_CANCEL at end of input (Ctrl-D), the same "backed out" a picker
# gives, so a caller can treat every way of saying no alike.
cx_ask_line() {
  local prompt="$1" def="${2:-}" tty="${CX_PICK_TTY_OUT:-/dev/tty}"
  CX_ASK_REPLY=""
  _cx_ask_open || return "$CX_PICK_CANCEL"
  if [ -n "$def" ]; then
    printf '%s%s%s [%s]: ' "$C_BOLD" "$prompt" "$C_RESET" "$def" >>"$tty"
  else
    printf '%s%s%s: ' "$C_BOLD" "$prompt" "$C_RESET" >>"$tty"
  fi
  _cx_ask_read || {
    printf '\n' >>"$tty"
    return "$CX_PICK_CANCEL"
  }
  [ -n "$CX_ASK_REPLY" ] || CX_ASK_REPLY="$def"
  return 0
}

# cx_ask_yn PROMPT DEFAULT — yes (0) or no (1). DEFAULT is y or n, and is
# what an empty answer means; the capital in [Y/n] says which. Anything else
# is asked again rather than guessed at. End of input is CX_PICK_CANCEL.
cx_ask_yn() {
  local prompt="$1" def="${2:-n}" tty="${CX_PICK_TTY_OUT:-/dev/tty}" choices="y/N"
  case "$def" in
    y | Y)
      def=y
      choices="Y/n"
      ;;
    *) def=n ;;
  esac
  _cx_ask_open || return "$CX_PICK_CANCEL"
  while :; do
    printf '%s%s%s [%s] ' "$C_BOLD" "$prompt" "$C_RESET" "$choices" >>"$tty"
    _cx_ask_read || {
      printf '\n' >>"$tty"
      return "$CX_PICK_CANCEL"
    }
    case "$CX_ASK_REPLY" in
      '') [ "$def" = y ] && return 0 ;;
      y | Y | yes | YES | Yes) return 0 ;;
    esac
    case "$CX_ASK_REPLY" in
      '' | n | N | no | NO | No) return 1 ;;
    esac
    printf '  %splease answer y or n%s\n' "$C_YELLOW" "$C_RESET" >>"$tty"
  done
}
