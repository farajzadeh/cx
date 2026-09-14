#!/usr/bin/env bash
# lib/cmd/bar.sh — `cx bar` — one line for a tmux status bar.
#
# The same question as `cx peek`, in the shape a status line can use: which
# sessions are waiting for you, on one line, and nothing at all when the answer
# is none.
#
# TMUX IS THE LOOP, and that is the whole point. cx has no loop anywhere (see
# CLAUDE.md invariant 11) and this does not add one: `cx bar` runs once, prints
# a line and returns. `status-interval` decides how often that happens, which
# is exactly the "the interval comes from whatever is calling cx" rule — here
# the caller is tmux rather than a person or a driver agent.
#
# Every failure is silent and exit 0. A status line is not a place to report an
# error: it is redrawn every few seconds, it has one line, and a user who is
# looking at it is not in a position to act. Unreachable servers are the one
# exception — they are named, because a bar that empties out when the VPN drops
# would otherwise say "nothing needs you", which is a lie.

# shellcheck source=../hosts.sh
. "$CX_HOME/lib/hosts.sh"
# shellcheck source=../activity.sh
. "$CX_HOME/lib/activity.sh"
# shellcheck source=../remote.sh
. "$CX_HOME/lib/remote.sh"

# Set from --plain. A global rather than a parameter because every styling
# helper below would otherwise thread it through unread.
_CX_BAR_PLAIN=0

# _bar_fetch HOSTS DIR — one observe per host, in parallel, into DIR.
#
# --tail 0 because the bar needs the state and nothing else: the last message's
# role and stop_reason come back regardless, and the message bodies are the
# expensive half of the payload.
_bar_fetch() {
  local hosts="$1" dir="$2" h safe rc
  for h in $hosts; do
    safe=$(cx_sanitize "$h")
    # A server known to be down is skipped rather than waited on. This is the
    # negative cache used for speed and nothing else (invariant 4): the bar
    # redraws every interval, and paying ConnectTimeout per dead host on each
    # redraw is the difference between a status line and a stall.
    if cx_cache_is_down "$h"; then
      printf '' >"$dir/$safe.rc"
      continue
    fi
    (
      rc=0
      cx_agent "$h" observe --all --tail 0 >"$dir/$safe.json" 2>/dev/null || rc=$?
      [ "$rc" = 0 ] || printf '%s' "$rc" >"$dir/$safe.rc"
    ) &
  done
  wait
}

# _bar_style STATE — the tmux style sequence for a state.
_bar_style() {
  [ "$_CX_BAR_PLAIN" = 1 ] && return 0
  case "$1" in
    blocked) printf '#[fg=yellow]' ;;
    idle | fresh) printf '#[fg=green]' ;;
    working) printf '#[fg=cyan]' ;;
    dead | unreachable) printf '#[fg=red]' ;;
    *) printf '#[fg=default]' ;;
  esac
}

# _bar_icon STATE — one glyph for a tab title.
#
# Shape carries the meaning and colour only reinforces it: a status bar is
# read at a glance and out of the corner of an eye, and plenty of people
# cannot tell the green one from the yellow one. Geometric shapes rather than
# a Nerd Font, so this works in whatever terminal you already have.
_bar_icon() {
  case "$1" in
    idle) printf '\xe2\x97\x8f' ;;    # ● solid: finished, waiting for you
    working) printf '\xe2\x97\x90' ;; # ◐ half:  mid-turn
    blocked) printf '\xe2\x96\xb2' ;; # ▲ warn:  needs an answer only you have
    fresh) printf '\xe2\x97\x8b' ;;   # ○ open:  up, nothing asked of it yet
    dead) printf '\xe2\x9c\x97' ;;    # ✗
    *) printf '?' ;;
  esac
}

_bar_reset() {
  [ "$_CX_BAR_PLAIN" = 1 ] && return 0
  printf '#[default]'
}

# _bar_escape TEXT — a name, safe to put in a tmux format string.
#
# tmux expands `#` in the output of #(), so a literal one has to be doubled or
# it swallows what follows. Nothing cx names can contain a `#` today — project
# names reject it and labels are [A-Za-z0-9_-] — but an SSH host alias is the
# user's own string, and a bar that mangles itself is a bad way to find out.
_bar_escape() {
  [ "$_CX_BAR_PLAIN" = 1 ] && {
    printf '%s' "$1"
    return 0
  }
  printf '%s' "$1" | sed 's/#/##/g'
}

# _bar_name HOST TARGET QUALIFY — how a session is written in the bar.
#
# Qualified with its host only when there is more than one server: with a
# single server every name would carry the same prefix, which costs width and
# says nothing.
_bar_name() {
  if [ "$3" = 1 ]; then
    _bar_escape "$1:$2"
  else
    _bar_escape "$2"
  fi
}

# _bar_window TARGET — one tab's icon, from the cache and nothing else.
#
# Run once per tmux window on every status redraw, so it touches no network:
# it reads the state cache that the aggregate `cx bar` refreshes. See
# lib/cache.sh.
#
# Prints NOTHING when the cache cannot answer — no target (a window that is
# not a cx session), no file, too old, or a session it has never seen. A tab
# that is not a cx tab should look exactly like it always did, and an icon
# asserted from a stale file is worse than no icon.
_bar_window() {
  local target="$1" state=""
  [ -n "$target" ] || return 0
  state=$(cx_state_read "$target" 2>/dev/null) || return 0
  [ -n "$state" ] || return 0
  printf '%s%s%s' "$(_bar_style "$state")" "$(_bar_icon "$state")" "$(_bar_reset)"
}

_bar_setup() {
  local self="$CX_HOME/bin/cx"
  cat <<EOF
# cx — the sessions waiting for you, in the tmux status bar.
# Append to ~/.tmux.conf, then: tmux source-file ~/.tmux.conf

set -g status-interval 30
set -g status-right-length 100
set -g status-right "#($self bar) #[default]%H:%M"

# Per-tab state. Every window cx open was run in carries an @cx_target, and
# these two lines turn it into an icon in the tab title. Windows without one
# are untouched and look exactly as they did.
setw -g window-status-format         " #I #($self bar --window '#{@cx_target}')#W "
setw -g window-status-current-format "#[bold] #I #($self bar --window '#{@cx_target}')#W "

# Notes
#   * The absolute path is deliberate: tmux runs status commands under the
#     environment its server started with, which usually has no ~/.local/bin.
#   * status-interval is one SSH round trip per server. 30s is a reasonable
#     floor; 10s is a lot of connections for a line you glance at.
#   * If your SSH key needs an agent, the tmux server needs to see it:
#     add SSH_AUTH_SOCK to update-environment, or run cx from a terminal
#     first — the shared connection cx opens is reused for a while.
#   * The tab icons come from the same fetch as the line on the right: the
#     aggregate job refreshes a state cache, the per-tab lookups read it and
#     touch no network at all. Drop the status-right line and the tabs lose
#     their icons, because nothing is refreshing that cache any more.
EOF
}

cmd_bar() {
  local max=3 states="blocked,idle" label="cx" attached_too=0
  local window="" window_mode=0

  _CX_BAR_PLAIN=0

  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        cat <<EOF
${C_BOLD}cx bar${C_RESET} — the sessions waiting for you, on one line

  cx bar                        one line, styled for tmux
  cx bar --setup                the ~/.tmux.conf lines to make it appear
  cx bar --plain                no tmux styling, for a prompt or another bar

Prints the sessions that are waiting for a human, most urgent first:

  ${C_YELLOW}blocked${C_RESET}    stopped mid-turn and gone quiet — usually a permission prompt
  ${C_GREEN}idle${C_RESET}       the last turn finished

  ${C_DIM}cx 3: api@review web2:dash api/authfix@tests${C_RESET}

and ${C_BOLD}nothing at all${C_RESET} when nothing is waiting, so the bar collapses. A server
that could not be reached is named as ${C_RED}!host${C_RESET} rather than passed over — an
empty bar has to mean "nothing needs you", not "cx could not tell".

A session you have attached is left out, for the same reason cx nudge will not
type into one: you are already looking at it. ${C_BOLD}--attached${C_RESET} includes them.

${C_BOLD}OPTIONS${C_RESET}
  --attached      include sessions you already have open
  --max N         how many to name before "+N" (default 3; 0 counts only)
  --states LIST   which states count as waiting, in priority order
                  (default blocked,idle; also fresh, working, dead, unknown)
  --label TEXT    the prefix (default "cx"; empty for none)
  --plain         no #[...] styling
  --setup         print tmux configuration and exit

Each redraw is one SSH round trip per server, so put the interval where it
belongs — in tmux, not here. There is no --follow anywhere in cx.

Related: cx peek (the same facts as a table), cx nudge (answer one)
EOF
        return 0
        ;;
      --setup)
        _bar_setup
        return 0
        ;;
      --plain) _CX_BAR_PLAIN=1 ;;
      --attached) attached_too=1 ;;
      --window)
        # The value may legitimately be empty: tmux expands #{@cx_target} to
        # nothing for a window that is not a cx session, and the right answer
        # there is to print nothing rather than to complain.
        [ $# -ge 2 ] || {
          err "--window needs a target"
          return 3
        }
        window_mode=1
        window="$2"
        shift
        ;;
      --max)
        [ $# -ge 2 ] || {
          err "--max needs a number"
          return 3
        }
        max="$2"
        shift
        ;;
      --states)
        [ $# -ge 2 ] || {
          err "--states needs a list"
          return 3
        }
        states="$2"
        shift
        ;;
      --label)
        [ $# -ge 2 ] || {
          err "--label needs a value"
          return 3
        }
        label="$2"
        shift
        ;;
      -*)
        err "unknown option: $1"
        return 3
        ;;
      *)
        err "cx bar takes no arguments"
        hint "narrow it with --states, or ask about one session with: cx peek <target>"
        return 3
        ;;
    esac
    shift
  done

  # One tab's icon, read from the cache. Nothing below this point runs: no
  # hosts are contacted, no states are validated, nothing is fetched.
  if [ "$window_mode" = 1 ]; then
    _bar_window "$window"
    return 0
  fi

  case "$max" in
    '' | *[!0-9]*)
      err "--max wants a number"
      return 3
      ;;
  esac

  local state_list="" st
  for st in $(printf '%s' "$states" | tr ',' ' '); do
    case "$st" in
      idle | blocked | working | fresh | dead | unknown) state_list="$state_list $st" ;;
      *)
        err "unknown state: $st"
        hint "one of: idle, blocked, working, fresh, dead, unknown"
        return 3
        ;;
    esac
  done
  [ -n "$state_list" ] || {
    err "--states is empty"
    return 3
  }

  local hosts
  hosts=$(cx_hosts_list)
  [ -n "$hosts" ] || return 0

  local qualify=0
  [ "$(printf '%s\n' "$hosts" | grep -c .)" -gt 1 ] && qualify=1

  local tmp
  tmp=$(cx_mktempdir)
  _bar_fetch "$hosts" "$tmp"

  local now h safe rows="" down="" rc
  now=$(cx_now)

  for h in $hosts; do
    safe=$(cx_sanitize "$h")
    if [ -s "$tmp/$safe.json" ] && jq -e . "$tmp/$safe.json" >/dev/null 2>&1; then
      cx_cache_clear_down "$h"
      rows="$rows$(cx_activity_rows "$h" "$tmp/$safe.json" "$now")
"
    else
      down="$down $h"
      # 255 is ssh's own "could not connect"; anything else came back from the
      # far side, which means the host is up and something else is wrong —
      # an agent too old for observe, most likely. Marking that host down would
      # make cx ls lie about it for the next minute.
      rc=$(cat "$tmp/$safe.rc" 2>/dev/null) || rc=""
      [ "$rc" = 255 ] && cx_cache_mark_down "$h"
    fi
  done
  rm -rf "$tmp"

  # The per-tab lookups must not touch the network, so they read a cache, and
  # this is the fetch that fills it — the same arrangement shell completion
  # has with cx_cache_write_targets. Written from the unfiltered rows, before
  # anything below narrows them to the states being watched for.
  printf '%s' "$rows" | cx_state_write

  # Selected in the order --states named them, so the list doubles as the
  # priority: what is written first is what you see when the bar is truncated.
  local picked="" target rstate attached quiet age
  for st in $state_list; do
    # quiet and age are read only so that their columns are consumed: the bar
    # says which sessions are waiting, never for how long.
    # shellcheck disable=SC2034
    while IFS='	' read -r h target rstate attached quiet age; do
      [ -n "$target" ] || continue
      [ "$rstate" = "$st" ] || continue
      # A session with a client attached is one you are already looking at, so
      # naming it in the status bar tells you nothing you cannot see. Same
      # reasoning as cx nudge refusing to type into an attached session.
      [ "$attached_too" = 1 ] || [ "$attached" != true ] || continue
      picked="$picked$rstate	$(_bar_name "$h" "$target" "$qualify")
"
    done <<EOF
$rows
EOF
  done
  picked=$(printf '%s' "$picked" | grep -v '^$' || true)

  local count text=""
  count=$(printf '%s' "$picked" | grep -c . || true)
  count="${count:-0}"

  if [ "$count" -gt 0 ]; then
    local first nm i=0
    first=$(printf '%s\n' "$picked" | head -1 | cut -f1)
    text="$(_bar_style "$first")${label:+$label }$count"
    [ "$max" -gt 0 ] && text="$text:"
    text="$text$(_bar_reset)"

    while IFS='	' read -r st nm; do
      [ -n "$nm" ] || continue
      i=$((i + 1))
      [ "$i" -le "$max" ] || break
      text="$text $(_bar_style "$st")$nm$(_bar_reset)"
    done <<EOF
$picked
EOF

    if [ "$max" -gt 0 ] && [ "$count" -gt "$max" ]; then
      text="$text +$((count - max))"
    fi
  fi

  local d
  for d in $down; do
    text="${text:+$text }$(_bar_style unreachable)!$(_bar_escape "$d")$(_bar_reset)"
  done

  [ -n "$text" ] || return 0
  printf '%s\n' "$text"
}
