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
#
# --query Q starts with Q already typed: fzf's own --query, the built-in
# menu's filter. --always-ask shows the menu even when there is only one
# candidate (or the query leaves only one), for a caller whose next step acts
# without asking again — "there was only one, so I stopped it" is not an
# acceptable surprise.
cx_pick() {
  local prompt="select" header="" preview="" rows
  _CX_PICK_QUERY=""
  _CX_PICK_ALWAYS=0
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
      --query)
        _CX_PICK_QUERY="$2"; shift
        ;;
      --always-ask) _CX_PICK_ALWAYS=1 ;;
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
    --no-multi --exit-0 --prompt="$prompt> "
  [ "${_CX_PICK_ALWAYS:-0}" = 1 ] || set -- "$@" --select-1
  [ -n "${_CX_PICK_QUERY:-}" ] && set -- "$@" --query="$_CX_PICK_QUERY"
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
  local prompt="$1" header="$2" rows="$3" filter="${_CX_PICK_QUERY:-}" shown n answer max=20 total pick
  local tty_in="${CX_PICK_TTY_IN:-/dev/tty}" tty="${CX_PICK_TTY_OUT:-/dev/tty}"
  # Whether a single match may choose itself. Typing is always a choice; a
  # pre-seeded query only is when the caller did not ask for --always-ask.
  local auto=1
  [ "${_CX_PICK_ALWAYS:-0}" = 1 ] && auto=0

  # When there is only one candidate, there is no question to ask.
  if [ "$auto" = 1 ] && [ "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" = 1 ]; then
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

    if [ -n "$filter" ] && [ "$total" = 1 ] && [ "$auto" = 1 ]; then
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
      *[!0-9]*)
        filter="$answer"
        auto=1
        ;;
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
#   worktree  worktrees only
#   session   live tmux sessions, @label ones included (asks the servers)
#   any       unit + session, one row per target
#   finished  sessions the state cache last saw dead, then every unit
#
# Built from the same listing `cx ls` shows, through the same cache, so a
# warm picker costs what a warm `cx ls` does. Split from cx_pick_target so a
# test can check what would be offered without a terminal. The kinds after
# unit are built in _cx_pick_candidates_more, below.
cx_pick_candidates() {
  local kind="$1" only="${2:-}"
  case "$kind" in
    worktree | session | any | finished)
      _cx_pick_candidates_more "$kind" "$only"
      return
      ;;
  esac
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

# cx_pick_target KIND [PROMPT] [HOST] [CX_PICK_OPTIONS...] — choose a target
# interactively.
#
# Prints host:project[/worktree][@label]. Returns CX_PICK_CANCEL on cancel and
# 2 when there is nothing to choose from. Anything after HOST goes to cx_pick
# as it is (--always-ask, --query, --header); pass "" for HOST to mean all.
cx_pick_target() {
  local kind="$1" prompt="${2:-target}" only="${3:-}" rows
  if [ $# -ge 3 ]; then shift 3; else set --; fi
  cx_spinner_start "querying servers" 2>/dev/null || true
  rows=$(cx_pick_candidates "$kind" "$only")
  cx_spinner_stop 2>/dev/null || true
  [ -n "$rows" ] || {
    _cx_pick_none "$kind"
    return 2
  }
  printf '%s\n' "$rows" |
    cx_pick --prompt "$prompt" --preview "$(cx_pick_preview_cmd)" "$@"
}

# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------

# cx_pick_live [HOST] — every live session, as "host:target<TAB>attached".
#
# The agent's `sessions` verb on every host at once, which is the question cx
# tabs asks and for the same reason: "is there a tmux session" is one
# list-sessions per host, where observe reads a transcript per session and
# takes several times as long. Live sessions are the one candidate the cached
# listing cannot supply — a label exists only in tmux — so this is the one
# place a picker goes to the network.
#
# A host the cache already remembers as unreachable is skipped rather than
# waited on, and one that fails now is simply absent: a menu of what could be
# reached is more use than an error about what could not.
cx_pick_live() {
  local only="${1:-}" hosts h safe dir
  # shellcheck source=projects.sh
  . "$CX_HOME/lib/projects.sh"
  hosts=$(cx_hosts_list)
  [ -n "$hosts" ] || return 0
  dir=$(cx_mktempdir) || return 0

  local asked=""
  for h in $hosts; do
    [ -z "$only" ] || [ "$h" = "$only" ] || continue
    cx_cache_is_down "$h" && continue
    asked="$asked $h"
    safe=$(cx_sanitize "$h")
    (cx_agent "$h" sessions >"$dir/$safe.json" 2>/dev/null ||
      rm -f "$dir/$safe.json") &
  done
  wait

  for h in $asked; do
    safe=$(cx_sanitize "$h")
    # Said, not hidden: otherwise one server failing to answer reads as
    # "nothing is running", which is a different and wrong statement.
    [ -s "$dir/$safe.json" ] || {
      warn "$h did not answer — its live sessions are not listed"
      continue
    }
    jq -r --arg h "$h" '
      .sessions[]? | select(.target != null)
      | "\($h):\(.target)\t\(.attached)"' "$dir/$safe.json" 2>/dev/null || true
  done
  rm -rf "$dir"
}

# _cx_pick_state — append each row's cached state as a last column.
#
# From the state file cx bar and cx peek keep (cx_state_rows), so it costs no
# network and is allowed to be missing: no state is an empty column, never a
# guess. The states and the rows travel through one awk as tagged lines,
# because bash 3.2 has no process substitution worth relying on and awk -v
# cannot carry newlines portably.
_cx_pick_state() {
  local states
  states=$(cx_state_rows 2>/dev/null) || states=""
  {
    [ -n "$states" ] && printf '%s\n' "$states" | awk '{ print "S\t" $0 }'
    awk '{ print "R\t" $0 }'
  } | awk -F'\t' '
    $1 == "S" { s[$2] = $3; next }
    { line = $2
      for (i = 3; i <= NF; i++) line = line "\t" $i
      print line "\t" (($2 in s) ? s[$2] : "") }'
}

# _cx_pick_dedupe — keep the first row for each value.
_cx_pick_dedupe() { awk -F'\t' '$1 != "" && !seen[$1]++'; }

# _cx_pick_session_rows [HOST] — live sessions as candidate rows.
_cx_pick_session_rows() {
  cx_pick_live "${1:-}" | awk -F'\t' '$1 != "" {
    printf "%s\t%s\tsession\t%s\n", $1, $1, ($2 == "true" ? "● attached" : "●") }'
}

# _cx_pick_candidates_more KIND HOST — the kinds cx_pick_candidates hands on.
_cx_pick_candidates_more() {
  local kind="$1" only="$2"
  case "$kind" in
    worktree)
      cx_pick_candidates unit "$only" | awk -F'\t' 'index($1, "/")'
      ;;
    session)
      _cx_pick_session_rows "$only" | _cx_pick_state
      ;;
    any)
      # Units first, so a project's default session — the same target as the
      # project itself — shows once, with its branch.
      {
        cx_pick_candidates unit "$only"
        _cx_pick_session_rows "$only"
      } | _cx_pick_dedupe | _cx_pick_state
      ;;
    finished)
      # What cx forget is for: a session last seen dead, which only the state
      # cache knows without asking every server to read every transcript.
      # Then every unit, because that cache is often cold and forget takes a
      # unit's default session too.
      {
        cx_state_rows 2>/dev/null | awk -F'\t' -v only="$only" '
          $2 == "dead" && (only == "" || index($1, only ":") == 1) {
            printf "%s\t%s\tfinished\n", $1, $1 }'
        cx_pick_candidates unit "$only"
      } | _cx_pick_dedupe
      ;;
  esac
  return 0
}

# _cx_pick_none KIND — say that there was nothing to offer, and what to do.
_cx_pick_none() {
  case "$1" in
    session)
      err "no live sessions to choose from"
      hint "start one with: cx open -d <host>:<project>"
      ;;
    worktree)
      err "no worktrees to choose from"
      hint "make one with: cx wt add <host>:<project>/<name>"
      ;;
    *)
      err "no projects to choose from"
      hint "create one with: cx new <host>:<name>"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# The fzf preview
# ---------------------------------------------------------------------------
#
# fzf runs the preview command for every row the cursor lands on, so it must
# be quick and it must never wait on a server: a preview that hangs freezes
# the cursor. It therefore reads cache files and nothing else — the cached
# listing (any age) and the state file — and says how old they are. A cold
# cache gives a short preview, never a slow one.

# cx_pick_preview_cmd — the --preview string: this installation's cx, asked
# for a preview of fzf's {1}. Empty (no preview) when there is no bin/cx to
# run, which is only ever a partial checkout.
cx_pick_preview_cmd() {
  [ -x "$CX_HOME/bin/cx" ] || return 0
  printf "'%s' find --preview {1}" \
    "$(printf '%s' "$CX_HOME/bin/cx" | sed "s/'/'\\\\''/g")"
}

# cx_pick_preview TARGET — what fzf shows beside the highlighted row.
cx_pick_preview() {
  # fzf hands over the field with its delimiter on some versions; a target
  # never contains whitespace, so dropping all of it is safe.
  local t host rest label="" wt="" project unit f age json now
  t=$(printf '%s' "${1:-}" | tr -d ' \t\r\n')

  case "$t" in
    +new)
      printf 'A new session: its own conversation, on the same files.\n\n'
      printf 'Choose the project or worktree next, then name the session\n'
      printf '(letters, digits, _ and -). It opens as <target>@<name>.\n'
      return 0
      ;;
    *:*) ;;
    *)
      printf '%s\n' "$t"
      return 0
      ;;
  esac

  host="${t%%:*}"
  rest="${t#*:}"
  case "$rest" in *@*)
    label="${rest#*@}"
    rest="${rest%%@*}"
    ;;
  esac
  project="${rest%%/*}"
  case "$rest" in */*) wt="${rest#*/}" ;; esac
  unit="$host:$rest"

  printf '%s\n' "$t"
  [ -n "$label" ] && printf '  session @%s on %s\n' "$label" "$unit"
  printf '\n'

  # Sessions of this unit the state cache has seen, whatever its age: a
  # preview labels old data rather than hiding it.
  f=$(cx_state_file)
  if [ -s "$f" ] && awk -F'\t' -v u="$unit" '
    $1 == u || index($1, u "@") == 1 { found = 1 } END { exit !found }' "$f"; then
    awk -F'\t' -v u="$unit" '
      $1 == u || index($1, u "@") == 1 {
        printf "  %-10s %-30s %s\n", (n++ ? "" : "sessions"), $1, $2 }' "$f"
    age=$(cx_age "$f" 2>/dev/null) || age=""
    [ -n "$age" ] && printf '  (states seen %s ago — cx peek refreshes)\n' "$(cx_human_age "$age")"
    printf '\n'
  fi

  json=$(cx_cache_read "$host" 2>/dev/null) || json=""
  if [ -z "$json" ]; then
    printf '  nothing cached for %s yet — cx ls fetches it\n' "$host"
    return 0
  fi
  now=$(cx_now)
  printf '%s' "$json" | jq -r --arg p "$project" --arg w "$wt" --argjson now "$now" '
    def ago: ($now - .) as $s
      | if $s < 60 then "\($s)s" elif $s < 3600 then "\($s / 60 | floor)m"
        elif $s < 86400 then "\($s / 3600 | floor)h" else "\($s / 86400 | floor)d" end
      | . + " ago";
    ([ .projects[]? | select(.name == $p) ] | first // null) as $proj
    | if $proj == null then "  not in the cached listing — cx ls -r refreshes it"
      else
        (if $w == "" then $proj
         else ([ ($proj.worktrees // [])[] | select(.name == $w) ] | first // null) end)
        | if . == null then "  no worktree \($w) in the cached listing"
          else
            "  branch     \(.branch // "—")\(if .dirty == true then "  (uncommitted changes)" else "" end)",
            "  tmux       \(.tmux_count // 0) live",
            (if .sessions != null then "  history    \(.sessions) conversation(s)" else empty end),
            (if .last_active != null then "  active     \(.last_active | ago)" else empty end),
            (if .path != null then "  path       \(.path)" else empty end),
            (if $w == "" and ($proj.repo // "") != "" then "  repo       \($proj.repo)" else empty end),
            (if $w == "" and (($proj.worktrees // []) | length) > 0
             then "  worktrees  \($proj.worktrees | map(.name) | join(", "))" else empty end)
          end
      end' 2>/dev/null || true
  age=$(cx_cache_age "$host" 2>/dev/null) || age=""
  [ -n "$age" ] && printf '\n  (listing cached %s ago — cx ls -r refreshes)\n' "$(cx_human_age "$age")"
  return 0
}

# ---------------------------------------------------------------------------
# Target or pick
# ---------------------------------------------------------------------------

# cx_pick_readline PROMPT — one line of text from the human, on stdout.
#
# From the terminal rather than stdin, for the same reason the menu is.
# Returns CX_PICK_CANCEL on end of input or an empty answer: an empty label
# or an empty prompt is never what was meant.
cx_pick_readline() {
  local tty_in="${CX_PICK_TTY_IN:-/dev/tty}" tty="${CX_PICK_TTY_OUT:-/dev/tty}" line=""
  { printf '%s%s>%s ' "$C_BOLD" "$1" "$C_RESET" >"$tty"; } 2>/dev/null || true
  { IFS= read -r line <"$tty_in"; } 2>/dev/null || return "$CX_PICK_CANCEL"
  [ -n "$line" ] || return "$CX_PICK_CANCEL"
  printf '%s\n' "$line"
}

# cx_pick_new_session — "+ new session…": a unit, then a label for it.
#
# Prints unit@label. The label is checked with the rule the target grammar
# uses, so a bad one is refused before anything reaches a server.
cx_pick_new_session() {
  local unit label
  # shellcheck source=target.sh
  . "$CX_HOME/lib/target.sh"
  unit=$(cx_pick_target unit "new session on") || return $?
  label=$(cx_pick_readline "name for the new session on $unit") || return $?
  _cx_target_label_ok "$label" || {
    err "invalid session label: $label"
    hint "labels may use letters, digits, underscore and hyphen"
    return 3
  }
  printf '%s@%s\n' "${unit%%@*}" "$label"
}

# cx_target_or_pick [--always-ask] [--new] KIND VERB [HINT...] — the target a
# command was not given, chosen by the human; on stdout.
#
# The one place the rule is written: with nobody at a terminal (cx_pick_ok),
# this is exactly the "no target given" error every command already had —
# same message, the command's own HINTs, exit 3 — so a script sees no change.
# With someone there, it offers KIND (see cx_pick_candidates) under the
# prompt VERB, and --new adds a "+ new session…" row at the end.
#
# Returns 130 (after a dim "cancelled") when the human backs out, so callers
# can simply `|| return $?`: a cancel is not an error to report again.
cx_target_or_pick() {
  local always="" new=0 kind verb rows pick rc=0 h
  while [ $# -gt 0 ]; do
    case "$1" in
      --always-ask) always=--always-ask ;;
      --new) new=1 ;;
      *) break ;;
    esac
    shift
  done
  kind="$1"
  verb="$2"
  shift 2

  if ! cx_pick_ok; then
    err "no target given"
    for h in "$@"; do hint "$h"; done
    return 3
  fi

  cx_spinner_start "looking for targets" 2>/dev/null || true
  rows=$(cx_pick_candidates "$kind") || rows=""
  cx_spinner_stop 2>/dev/null || true
  [ -n "$rows" ] || {
    _cx_pick_none "$kind"
    return 2
  }
  if [ "$new" = 1 ]; then
    # Never the only row, so it can never be chosen by default.
    rows="$rows
+new	+ new session…"
  fi

  pick=$(printf '%s\n' "$rows" |
    cx_pick --prompt "$verb" --preview "$(cx_pick_preview_cmd)" ${always:+"$always"}) || rc=$?
  if [ "$rc" = 0 ] && [ "$pick" = +new ]; then
    pick=$(cx_pick_new_session) || rc=$?
  fi
  case "$rc" in
    0) ;;
    "$CX_PICK_CANCEL")
      info "cancelled"
      return "$rc"
      ;;
    *) return "$rc" ;;
  esac

  # The menu is gone from the screen by now (fzf clears it), so say what was
  # chosen: the rest of the command's output is about it.
  info "$verb $pick"
  printf '%s\n' "$pick"
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
