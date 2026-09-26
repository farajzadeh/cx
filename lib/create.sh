#!/usr/bin/env bash
# lib/create.sh — what `cx new` and `cx wt add` share: asking for the parts of
# a new thing that were left off the command line, and opening a session in it
# once it exists.
#
# Opening is cmd_open, called, never re-implemented. Everything cx open does —
# the agent version gates, the sign-in warning, recording the permission mode,
# the bypass warning, detaching, tagging the local tmux window, exec'ing ssh —
# is subtle, and a second copy of it here would drift from the first the next
# time either changed. So the options below are only collected and checked;
# the words the user typed are handed to cmd_open exactly as typed, and it
# parses them itself.

[ -n "${_CX_CREATE_LOADED:-}" ] && return 0
_CX_CREATE_LOADED=1

# shellcheck source=target.sh
. "$CX_HOME/lib/target.sh"
# shellcheck source=pick.sh
. "$CX_HOME/lib/pick.sh"

# cx_create_opts_reset — forget every option collected so far.
cx_create_opts_reset() {
  CX_CREATE_OPEN_ARGS=()
  CX_CREATE_LABEL=""
  CX_CREATE_DETACH=0
  CX_CREATE_USED=0
  _CX_CREATE_YES=0
  _CX_CREATE_NO=0
  # The first option given that only makes sense with a session, so that a
  # clash with --no-open can name it.
  _CX_CREATE_IMPLIED=""
}
cx_create_opts_reset

_cx_create_imply() {
  [ -n "$_CX_CREATE_IMPLIED" ] || _CX_CREATE_IMPLIED="$1"
}

# cx_create_opt FLAG [VALUE] — consume one open-after-create option.
#
# The same contract as cx_claude_opt: 0 consumed (CX_CREATE_USED words), 1 not
# ours, 2 invalid and already reported. Call it directly, never inside $(...),
# or everything it records is lost with the subshell.
#
# Any option that describes the session — -d, --label, --no-hooks, a Claude
# option — implies --open. Asking for a detached session with no permission
# checks and then not getting one would be a strange way to read the request.
# shellcheck disable=SC2034  # CX_CREATE_USED is read by lib/cmd/*
cx_create_opt() {
  local flag="$1" value="${2:-}" rc=0
  CX_CREATE_USED=1

  case "$flag" in
    --open)
      _CX_CREATE_YES=1
      return 0
      ;;
    --no-open)
      _CX_CREATE_NO=1
      return 0
      ;;
    -d | --detach)
      CX_CREATE_DETACH=1
      CX_CREATE_OPEN_ARGS=("${CX_CREATE_OPEN_ARGS[@]+"${CX_CREATE_OPEN_ARGS[@]}"}" -d)
      _cx_create_imply "$flag"
      return 0
      ;;
    --no-hooks)
      CX_CREATE_OPEN_ARGS=("${CX_CREATE_OPEN_ARGS[@]+"${CX_CREATE_OPEN_ARGS[@]}"}" --no-hooks)
      _cx_create_imply "$flag"
      return 0
      ;;
    --label)
      _cx_target_label_ok "$value" || {
        err "invalid session label: ${value:-(missing)}"
        hint "labels may use letters, digits, underscore and hyphen"
        return 2
      }
      CX_CREATE_LABEL="$value"
      CX_CREATE_USED=2
      _cx_create_imply "$flag"
      return 0
      ;;
  esac

  # Claude's options: validated now, by the same function cx open uses, so a
  # typo fails before anything is created rather than after.
  cx_claude_opt "$flag" "$value" || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  CX_CREATE_USED="$CX_CLAUDE_USED"
  if [ "$CX_CLAUDE_USED" = 2 ]; then
    CX_CREATE_OPEN_ARGS=("${CX_CREATE_OPEN_ARGS[@]+"${CX_CREATE_OPEN_ARGS[@]}"}" "$flag" "$value")
  else
    CX_CREATE_OPEN_ARGS=("${CX_CREATE_OPEN_ARGS[@]+"${CX_CREATE_OPEN_ARGS[@]}"}" "$flag")
  fi
  _cx_create_imply "$flag"
  return 0
}

# cx_create_check — refuse contradictions, before anything is created.
cx_create_check() {
  if [ "$_CX_CREATE_NO" = 1 ]; then
    if [ "$_CX_CREATE_YES" = 1 ]; then
      err "--open and --no-open contradict each other"
      return 3
    fi
    if [ -n "$_CX_CREATE_IMPLIED" ]; then
      err "$_CX_CREATE_IMPLIED describes the session to open, but --no-open says not to open one"
      return 3
    fi
  fi
  # An attached session hands the terminal to Claude; there is no JSON to
  # report and nothing to report it to. Detached, the session is described
  # alongside the thing created.
  if [ "${CX_JSON:-0}" = 1 ] && cx_create_explicit && [ "$CX_CREATE_DETACH" != 1 ]; then
    err "--json with --open needs -d: an attached session has no JSON to report"
    return 3
  fi
  return 0
}

# cx_create_explicit — did the command line itself ask for a session?
cx_create_explicit() {
  [ "$_CX_CREATE_YES" = 1 ] || [ -n "$_CX_CREATE_IMPLIED" ]
}

# cx_create_want_open — open a session in what was just created?
#
# The command line decides first. Otherwise CX_OPEN_AFTER_CREATE: `ask` asks
# only when cx_pick_ok says a human is there — so a script, --json and -y all
# get the old behaviour of creating and returning — and `always` opens only
# when there is a terminal to attach, since opening means handing one over.
cx_create_want_open() {
  [ "$_CX_CREATE_NO" = 1 ] && return 1
  cx_create_explicit && return 0
  case "${CX_OPEN_AFTER_CREATE:-ask}" in
    always)
      [ "${CX_JSON:-0}" != 1 ] && _cx_pick_tty
      ;;
    ask)
      cx_pick_ok || return 1
      cx_ask_yn "Open a session in it now?" y
      ;;
    *) return 1 ;;
  esac
}

# cx_create_open TARGET — hand over to cx open.
#
# TARGET is host-qualified, so cmd_open resolves it without asking any other
# server. Returns whatever cmd_open does; attached, it does not return at all.
cx_create_open() {
  local t="$1"
  [ -n "$CX_CREATE_LABEL" ] && t="$t@$CX_CREATE_LABEL"
  # The question fd would otherwise be inherited by ssh for the whole session.
  cx_ask_reset
  load_cmd open || {
    err "cannot load cx open"
    return 1
  }
  cmd_open "${CX_CREATE_OPEN_ARGS[@]+"${CX_CREATE_OPEN_ARGS[@]}"}" "$t"
}

# cx_create_open_json CREATED_JSON TARGET — detached open, in --json.
#
# One object, not two lines: what was created, with the session under
# `.session` (null when opening failed, and the exit status says why).
cx_create_open_json() {
  local created="$1" target="$2" sess="" rc=0
  sess=$(cx_create_open "$target") || rc=$?
  printf '%s\n' "$sess" | jq -e . >/dev/null 2>&1 || sess=null
  printf '%s' "$created" | jq -c --argjson s "$sess" '. + {session: $s}'
  return "$rc"
}

# cx_project_name_ok NAME — the agent's _validate_name, for asking again
# before a round trip rather than failing after one. The agent still checks:
# it cannot trust the client. Prints why on failure.
cx_project_name_ok() {
  case "$1" in
    '') printf 'a name is needed' ;;
    . | .. | -*) printf 'not a usable name: %s' "$1" ;;
    .worktrees) printf "'.worktrees' is reserved for worktree storage" ;;
    *[!A-Za-z0-9._-]*)
      printf 'only letters, digits, dot, underscore and hyphen: %s' "$1"
      ;;
    *) return 0 ;;
  esac
  return 1
}

# cx_worktree_name_ok NAME — the same for a worktree name (no dot: see
# invariant 10 and _validate_label).
cx_worktree_name_ok() {
  case "$1" in
    '') printf 'a name is needed' ;;
    *)
      _cx_target_label_ok "$1" && return 0
      printf 'only letters, digits, underscore and hyphen, and no leading hyphen: %s' "$1"
      ;;
  esac
  return 1
}

# cx_ask_valid PROMPT CHECK [DEFAULT] — cx_ask_line until CHECK accepts it.
# CHECK is one of the *_ok functions above; its reason is shown, then the
# question asked again.
cx_ask_valid() {
  local prompt="$1" check="$2" def="${3:-}" why
  while :; do
    cx_ask_line "$prompt" "$def" || return $?
    why=$("$check" "$CX_ASK_REPLY") && return 0
    printf '  %s%s%s\n' "$C_YELLOW" "$why" "$C_RESET" >>"${CX_PICK_TTY_OUT:-/dev/tty}"
  done
}
