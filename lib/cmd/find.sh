#!/usr/bin/env bash
# lib/cmd/find.sh — `cx find` / `cx pick` — browse every target, then act.
#
# Everything cx could be pointed at — projects, worktrees and live sessions,
# @label ones included — in one menu, then a second, short menu of what to do
# with the one chosen. Each action is the ordinary command (cmd_open,
# cmd_stop, ...) run as if it had been typed, so find adds no behaviour of its
# own that could drift from theirs: it is only a way of arriving at a target.
#
# --print skips the second menu and prints the target, which is how the
# picker reaches commands that have no picker of their own and scripts that
# want one:  cx ask "$(cx find --print api)" "what changed?"
#
# pick.sh is a symlink to this file, the same way resume.sh is to open.sh.

# shellcheck source=../pick.sh
. "$CX_HOME/lib/pick.sh"

_find_usage() {
  cat <<EOF
${C_BOLD}cx find${C_RESET} — choose any target from a menu, then what to do with it

  cx find                 every project, worktree and live session
  cx find api             ...starting with "api" typed into the filter
  cx find --print [q]     print the chosen target and do nothing else
  cx pick                 the same command

After a target is chosen, a second menu offers: open, shell, code, peek,
nudge (asks for the text), stop, a new @session on the same files, and print.
Each runs the ordinary cx command, exactly as if you had typed it.

--print writes only the target to stdout, so it composes:

  cx ask "\$(cx find --print api)" "what changed today?"
  cx goal member add release "\$(cx find --print)"

The menu is fzf when it is installed, with a preview of the highlighted
target read from the cache (never from the network), and a numbered menu
with a text filter otherwise. CX_PICKER=builtin|fzf chooses; CX_PICKER=none
turns interactive picking off everywhere.

Needs a terminal: with none, or under --json or -y, it exits 3.

Most commands pick for themselves when the target is left out at a terminal
— cx open, cx stop, cx nudge, cx code, cx forget, cx rm, cx wt rm.
EOF
}

# _find_actions TARGET — the second menu's rows.
_find_actions() {
  local t="$1" unit="${1%%@*}"
  printf 'open\topen\tattach Claude (cx open %s)\n' "$t"
  printf 'shell\tshell\ta plain shell there (cx shell)\n'
  printf 'code\tcode\tVS Code over Remote-SSH (cx code %s)\n' "$unit"
  printf 'peek\tpeek\twhat it is doing now (cx peek)\n'
  printf 'nudge\tnudge\ttype a prompt into it (cx nudge)\n'
  printf 'stop\tstop\tend the session (cx stop)\n'
  printf 'new\tnew session\tanother conversation on %s (cx open %s@…)\n' "$unit" "$unit"
  printf 'print\tprint\tjust print the target\n'
}

# _find_run ACTION TARGET — run the chosen action as its own command would.
_find_run() {
  local action="$1" t="$2" unit="${2%%@*}" text label
  case "$action" in
    open | shell | peek | stop | code)
      load_cmd "$action" || return 1
      [ "$action" = code ] && t="$unit"
      "cmd_$action" "$t"
      ;;
    nudge)
      text=$(cx_pick_readline "prompt for $t") || {
        info "cancelled"
        return "$CX_PICK_CANCEL"
      }
      load_cmd nudge || return 1
      cmd_nudge "$t" "$text"
      ;;
    new)
      # shellcheck source=../target.sh
      . "$CX_HOME/lib/target.sh"
      label=$(cx_pick_readline "name for the new session on $unit") || {
        info "cancelled"
        return "$CX_PICK_CANCEL"
      }
      _cx_target_label_ok "$label" || {
        err "invalid session label: $label"
        hint "labels may use letters, digits, underscore and hyphen"
        return 3
      }
      load_cmd open || return 1
      cmd_open "$unit@$label"
      ;;
    print) printf '%s\n' "$t" ;;
    *)
      err "unknown action: $action"
      return 1
      ;;
  esac
}

cmd_find() {
  local print=0 query="" target rc=0 action

  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        _find_usage
        return 0
        ;;
      -p | --print) print=1 ;;
      # fzf's preview command. Not in the usage text: it is how the menu talks
      # to itself, and reads only the cache.
      --preview)
        cx_pick_preview "${2:-}"
        return 0
        ;;
      -*)
        err "unknown option: $1"
        return 3
        ;;
      *) query="${query:+$query }$1" ;;
    esac
    shift
  done

  if ! cx_pick_ok; then
    err "cx find needs a terminal to ask on"
    hint "for a list a script can read: cx ls --json, cx status --json"
    return 3
  fi

  cx_spinner_start "looking for targets" 2>/dev/null || true
  local rows
  rows=$(cx_pick_candidates any) || rows=""
  cx_spinner_stop 2>/dev/null || true
  [ -n "$rows" ] || {
    _cx_pick_none any
    return 2
  }

  target=$(printf '%s\n' "$rows" |
    cx_pick --prompt find --query "$query" --preview "$(cx_pick_preview_cmd)") || rc=$?
  case "$rc" in
    0) ;;
    "$CX_PICK_CANCEL")
      info "cancelled"
      return "$rc"
      ;;
    2)
      err "nothing matches: $query"
      return 2
      ;;
    *) return "$rc" ;;
  esac

  if [ "$print" = 1 ]; then
    printf '%s\n' "$target"
    return 0
  fi

  action=$(_find_actions "$target" |
    cx_pick --prompt "$target" --always-ask) || rc=$?
  case "$rc" in
    0) ;;
    "$CX_PICK_CANCEL")
      info "cancelled"
      return "$rc"
      ;;
    *) return "$rc" ;;
  esac

  _find_run "$action" "$target"
}

cmd_pick() { cmd_find "$@"; }
