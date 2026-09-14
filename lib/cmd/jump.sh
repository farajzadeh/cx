#!/usr/bin/env bash
# lib/cmd/jump.sh — `cx jump` — go to the tab of the session that needs you.
#
# The status bar says a session is waiting; this takes you there. Bound to a
# key by `cx bar --setup`, it turns the bar from information into navigation:
# one key lands on the most urgent session with a tab, the next press on the
# one after it.
#
# Reads only the state cache, the same way `cx bar --window` does: a key press
# must never wait on a server. -r refreshes the cache first for when there is
# no status line running to keep it fresh.
#
# One shot like every other verb. Cycling is not a loop and not state: the
# "next" session is whichever comes after the tab you are on now.

# _jump_say MESSAGE — tell the person who pressed the key.
#
# Inside tmux the output of a key binding's run-shell lands in a pane that has
# to be dismissed, which is worse than saying nothing. The status line's own
# message area is where a key's answer belongs.
_jump_say() {
  if [ -n "${TMUX:-}" ]; then
    tmux display-message "cx: $1" 2>/dev/null || true
  else
    say "$1"
  fi
}

cmd_jump() {
  local states="blocked,idle"

  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        cat <<EOF
${C_BOLD}cx jump${C_RESET} — go to the tab of the session most in need of you

  cx jump                 the first blocked session with a tab, else the first idle one
  cx jump -r              refresh session states from the servers first
  cx jump --states LIST   which states to go to, in priority order (default blocked,idle)

Press it again and it goes to the next one, cycling. It only goes to sessions
that already have a tab — see ${C_BOLD}cx tabs${C_RESET} — and reads the same state the tab
icons show, so it answers instantly and never waits on a server.

${C_BOLD}cx bar --setup${C_RESET} binds it to prefix + j.

Related: cx bar (the status line), cx tabs (a tab per session), cx peek
EOF
        return 0
        ;;
      --states)
        [ $# -ge 2 ] || {
          err "--states needs a list"
          return 3
        }
        states="$2"
        shift
        ;;
      -*)
        err "unknown option: $1"
        return 3
        ;;
      *)
        err "cx jump takes no target"
        hint "to open one session's tab: cx open $1"
        return 3
        ;;
    esac
    shift
  done

  local st state_list=""
  for st in $(printf '%s' "$states" | tr ',' ' '); do
    case "$st" in
      idle | blocked | working | fresh | starting | dead | unknown) state_list="$state_list $st" ;;
      *)
        err "unknown state: $st"
        return 3
        ;;
    esac
  done

  cx_have tmux || {
    err "tmux is not installed on this machine"
    return 1
  }

  # -r is the global --refresh. There is no cache to refresh from without a
  # fetch, so this is the one path here that touches the network — only when
  # asked, and through the same code the status line uses.
  if [ "${CX_REFRESH:-0}" = 1 ]; then
    # shellcheck source=bar.sh
    . "$CX_HOME/lib/cmd/bar.sh"
    cmd_bar --plain >/dev/null 2>&1 || true
  fi

  local rows
  rows=$(cx_state_rows 2>/dev/null) || rows=""
  if [ -z "$rows" ]; then
    _jump_say "no recent session state — is the cx status line running? (cx jump -r to fetch it)"
    return 0
  fi

  # Candidates in priority order: every session in the first state, then every
  # session in the next.
  local order=""
  for st in $state_list; do
    order="$order$(printf '%s\n' "$rows" | awk -F'\t' -v s="$st" '$2 == s { print $1 }')
"
  done
  order=$(printf '%s' "$order" | grep -v '^$' || true)
  if [ -z "$order" ]; then
    _jump_say "nothing is waiting for you"
    return 0
  fi

  # Every tab in every local session that knows which cx session it holds.
  local windows
  windows=$(tmux list-windows -a -F '#{session_name}	#{window_id}	#{@cx_target}' 2>/dev/null |
    awk -F'\t' '$3 != ""') || windows=""

  # Only candidates that have a tab can be jumped to. Keep the order.
  local reachable
  reachable=$(printf '%s\n' "$order" | awk -F'\t' -v w="$windows" '
    BEGIN { n = split(w, L, "\n"); for (i = 1; i <= n; i++) { split(L[i], f, "\t"); if (f[3] != "" && !(f[3] in tab)) tab[f[3]] = f[1] "\t" f[2] } }
    ($1 in tab) { print $1 "\t" tab[$1] }')
  if [ -z "$reachable" ]; then
    local first
    first=$(printf '%s\n' "$order" | head -n 1)
    _jump_say "$first is waiting but has no tab — open one with: cx open $first"
    return 0
  fi

  # Where we are now decides where "next" is.
  local here="" pick=""
  [ -n "${TMUX:-}" ] && here=$(tmux display-message -p '#{@cx_target}' 2>/dev/null) || here=""
  pick=$(printf '%s\n' "$reachable" | awk -F'\t' -v here="$here" '
    { t[NR] = $0; if ($1 == here) at = NR }
    END {
      if (NR == 0) exit
      i = (at == 0 || at == NR) ? 1 : at + 1
      print t[i]
    }')

  local target session wid
  IFS='	' read -r target session wid <<EOF
$pick
EOF

  if [ -z "${TMUX:-}" ]; then
    say "$target"
    hint "its tab is in tmux session '$session' — attach with: tmux attach -t $session"
    return 0
  fi

  tmux select-window -t "$wid" 2>/dev/null || true
  tmux switch-client -t "$session" 2>/dev/null || true
}
