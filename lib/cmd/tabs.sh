#!/usr/bin/env bash
# lib/cmd/tabs.sh — `cx tabs` — a tmux tab per live session, on this machine.
#
# The only command in cx that drives tmux on the CLIENT, and that is not the
# change of character it looks like: cx still runs no Claude here and still
# keeps no state here. Arranging the user's own terminal is the one thing a
# client is for, and every window this opens is a plain `cx open` doing exactly
# what it always did.
#
# "Live" is asked of the agent's `sessions` verb rather than `observe`, because
# "is there a tmux session" is a tmux question — one list-sessions per host,
# about a second — while observe reads a transcript per session and takes six.
# The state each tab shows is a separate concern: it comes from the cache
# `cx bar` keeps, costs nothing here, and is allowed to be missing. A tab with
# no icon is still a tab.
#
# One shot, like every other verb. It builds the windows and hands over the
# terminal; it does not stay running, watch for new sessions, or close tabs
# whose session ended. Re-run it — that is what makes it safe to re-run.

# shellcheck source=../hosts.sh
. "$CX_HOME/lib/hosts.sh"
# shellcheck source=../remote.sh
. "$CX_HOME/lib/remote.sh"

# _tabs_live HOSTS DIR — every live session, as "host:target<TAB>attached".
#
# Failures are collected rather than fatal: one unreachable server must not
# stop the tabs for the servers that answered.
_tabs_live() {
  local hosts="$1" dir="$2" h safe
  for h in $hosts; do
    safe=$(cx_sanitize "$h")
    (cx_agent "$h" sessions >"$dir/$safe.json" 2>/dev/null ||
      printf '' >"$dir/$safe.fail") &
  done
  wait

  for h in $hosts; do
    safe=$(cx_sanitize "$h")
    if [ -s "$dir/$safe.json" ] && jq -e . "$dir/$safe.json" >/dev/null 2>&1; then
      jq -r --arg h "$h" '
        .sessions[]?
        | select(.target != null)
        | "\($h):\(.target)\t\(.attached)"' "$dir/$safe.json" 2>/dev/null
    else
      printf '%s\n' "$h" >>"$dir/failed"
    fi
  done
}

# _tabs_size — the size to give a new session, as "COLS ROWS".
#
# A detached tmux session is 80x24, and `cx open` attaches with `tmux attach
# -d`, so every tab would resize the session it attaches to down to that. Size
# it to the terminal cx is being run from instead.
_tabs_size() {
  local c r
  c=$(tput cols 2>/dev/null) || c=""
  r=$(tput lines 2>/dev/null) || r=""
  case "$c" in '' | *[!0-9]*) c=200 ;; esac
  case "$r" in '' | *[!0-9]*) r=50 ;; esac
  printf '%s %s' "$c" "$r"
}

# _tabs_open SESSION TARGET NAME COLS ROWS — one window, tagged.
#
# The tag is set here as well as by `cx open` inside the window, for two
# reasons: the icon is there immediately rather than after the next redraw, and
# a re-run can tell which sessions already have a tab before any of the new
# windows have got round to tagging themselves.
_tabs_open() {
  local session="$1" target="$2" name="$3" cols="$4" rows="$5" id=""

  if tmux has-session -t "=$session" 2>/dev/null; then
    id=$(tmux new-window -P -F '#{window_id}' -t "=$session" \
      -n "$name" "cx open '$target'" 2>/dev/null) || return 1
  else
    tmux new-session -d -s "$session" -x "$cols" -y "$rows" \
      -n "$name" "cx open '$target'" 2>/dev/null || return 1
    id=$(tmux list-windows -t "=$session" -F '#{window_id}' 2>/dev/null | head -1)
  fi

  [ -n "$id" ] || return 0
  tmux set-option -w -t "$id" @cx_target "$target" >/dev/null 2>&1 || true
}

cmd_tabs() {
  local session="cx" dry=0 attach=1

  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        cat <<EOF
${C_BOLD}cx tabs${C_RESET} — open every live session as a tmux tab, here

  cx tabs                       build the "cx" session and attach to it
  cx tabs -n                    show what it would open, change nothing
  cx tabs -s work               use a session named "work"
  cx tabs --no-attach           build it, leave you where you are

One window per live session, each running ${C_BOLD}cx open${C_RESET} and labelled with that
session's state — see ${C_BOLD}cx bar --setup${C_RESET} for the tmux lines that draw the icons.

Re-running is safe and is how you pick up sessions started since: a session
that already has a tab is skipped. Tabs are never closed for you.

${C_YELLOW}A tab takes its session.${C_RESET} cx open attaches with ${C_BOLD}tmux attach -d${C_RESET}, which detaches
whoever was already there — otherwise a dropped SSH leaves a phantom client and
tmux sizes the window to the smallest one. So opening a tab for a session you
have up in another terminal takes it, and when that terminal reattaches it
takes it back and the tab closes. Attach from one place. Sessions this would
take are marked ${C_YELLOW}!${C_RESET} before anything happens, and ${C_BOLD}-n${C_RESET} shows them without acting.

Related: cx bar --setup (the icons), cx open (one more tab, by hand),
         cx status (what is running, as a table)
EOF
        return 0
        ;;
      -n | --dry-run) dry=1 ;;
      --no-attach) attach=0 ;;
      -s | --session)
        [ $# -ge 2 ] || {
          err "--session needs a name"
          return 3
        }
        session="$2"
        shift
        ;;
      -*)
        err "unknown option: $1"
        return 3
        ;;
      *)
        err "cx tabs takes no target: it opens every live session"
        hint "for one session in the window you are in: cx open $1"
        return 3
        ;;
    esac
    shift
  done

  cx_have tmux || {
    err "tmux is not installed on this machine"
    hint "cx tabs arranges YOUR terminal, so it needs a local tmux"
    return 1
  }

  local hosts
  hosts=$(cx_hosts_list)
  [ -n "$hosts" ] || {
    note "No servers configured."
    hint "add one with: cx host add"
    return 0
  }

  local tmp live
  tmp=$(cx_mktempdir)
  cx_spinner_start "looking for live sessions"
  live=$(_tabs_live "$hosts" "$tmp")
  cx_spinner_stop

  local failed=""
  [ -f "$tmp/failed" ] && failed=$(tr '\n' ' ' <"$tmp/failed")
  rm -rf "$tmp"

  if [ -z "$live" ]; then
    note "No live sessions to open."
    hint "start one with: cx open -d <host>:<project>"
    local x
    for x in $failed; do warn "$x unreachable — not included"; done
    return 0
  fi

  local existing=""
  if tmux has-session -t "=$session" 2>/dev/null; then
    existing=$(tmux list-windows -t "=$session" -F '#{@cx_target}' 2>/dev/null)
  fi

  local cols rows
  # Two numbers; splitting them is the point.
  # shellcheck disable=SC2046
  set -- $(_tabs_size)
  cols="$1"
  rows="$2"

  local target attached state added=0 skipped=0
  while IFS="$(printf '\t')" read -r target attached; do
    [ -n "$target" ] || continue

    if printf '%s\n' "$existing" | grep -qxF "$target"; then
      skipped=$((skipped + 1))
      continue
    fi

    # Free: whatever the bar last saw. Blank is fine and common — the cache may
    # be cold, and a tab is worth opening either way.
    state=$(cx_state_read "$target" 2>/dev/null) || state=""

    if [ "$attached" = true ]; then
      printf '  %s!%s %-30s %-8s %sopen elsewhere — this tab takes it%s\n' \
        "$C_YELLOW" "$C_RESET" "$target" "$state" "$C_DIM" "$C_RESET"
    else
      printf '  %s+%s %-30s %s\n' "$C_GREEN" "$C_RESET" "$target" "$state"
    fi

    [ "$dry" = 1 ] || _tabs_open "$session" "$target" "${target#*:}" "$cols" "$rows" || {
      warn "could not open a tab for $target"
      continue
    }
    added=$((added + 1))
  done <<EOF
$live
EOF

  local x
  for x in $failed; do warn "$x unreachable — its sessions are not included"; done

  if [ "$dry" = 1 ]; then
    say ""
    note "$added to open, $skipped already there — nothing was changed."
    return 0
  fi

  say ""
  if [ "$added" = 0 ]; then
    note "Nothing new: all $skipped live sessions already have a tab."
  else
    say "opened $added tab(s) in \"$session\"${skipped:+, $skipped already there}"
  fi

  [ "$attach" = 1 ] || {
    hint "attach with: tmux attach -t $session"
    return 0
  }

  # Inside tmux already: attaching would nest, so move this client instead.
  # Otherwise hand the terminal over the way cx open does.
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "=$session"
  else
    exec tmux attach -t "=$session"
  fi
}
