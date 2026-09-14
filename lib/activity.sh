#!/usr/bin/env bash
# lib/activity.sh — what a session's raw facts mean.
#
# The client half of the agent's `observe` verb. The agent reports facts and
# nothing else; deciding that "quiet for ninety seconds with an unfinished tool
# call" means stuck is policy, and policy lives here for two reasons:
#
#   * the threshold is the user's to set (CX_IDLE_GRACE), and the agent has no
#     business carrying a client preference to every server, and
#   * this is the only part of the feature that can be a pure function, so it
#     is the only part a unit test can pin. Inside server/cx-agent — a
#     monolith that cannot be sourced piecemeal — it would be untestable.
#
# cx classifies STRUCTURE, never MEANING. "The last main-thread message is an
# assistant turn that ended with end_turn" is structure. "The definition of
# done is met" is meaning, and nothing in cx is allowed to decide it.

[ -n "${_CX_ACTIVITY_LOADED:-}" ] && return 0
_CX_ACTIVITY_LOADED=1

# How long a transcript may go quiet before a session that is mid-turn is
# called stuck rather than busy. Claude routinely spends a minute inside one
# tool call, so this is deliberately generous: a false "blocked" costs a
# pointless nudge, a false "working" costs a driver that waits forever.
: "${CX_IDLE_GRACE:=120}"

# How many trailing messages to ask the agent for. Enough to see what the
# session was doing, not so many that a fan-out over a dozen sessions turns
# into a megabyte of JSON.
: "${CX_PEEK_TAIL:=6}"

export CX_IDLE_GRACE CX_PEEK_TAIL

# cx_activity_state ALIVE SHELL UUID PRESENT LAST_ROLE LAST_STOP QUIET
#                   [CLAUDE_STATUS CLAUDE_KIND EVENT HOOKED]
#
# ALIVE/SHELL/PRESENT are the strings "true" or "false"; UUID and the LAST_*
# fields are empty when unknown; QUIET is seconds since the transcript was last
# written, or empty.
#
# The three optional facts are better sources than the transcript when the
# agent has them, and each is empty when it does not:
#
#   CLAUDE_STATUS  idle, busy or waiting, from Claude Code's own per-process
#                  status file. `waiting` is a permission prompt on screen —
#                  verified against a real session. Undocumented, like the
#                  transcript layout, and checked by the agent to belong to a
#                  process that is still running.
#   CLAUDE_KIND    interactive or bg. A background session has no tmux at all.
#   EVENT          what a Claude Code hook last reported: working, blocked,
#                  idle or fresh. Only sessions cx started with its hooks have
#                  one, and the agent drops a report older than the tmux session
#                  it would describe.
#   HOOKED         "true" when cx started the session with its hooks, so Claude
#                  is expected to report — and saying nothing means it has not
#                  finished starting.
#
# CLAUDE_STATUS BEATS EVENT, and the order was found the hard way. Pressing
# Escape at a permission prompt fires no hook at all — no Stop, nothing — so a
# hook's `blocked` outlives the prompt it described, while the status file
# goes back to idle the moment the prompt is dismissed. A hook's report is used
# only where there is no status file to consult.
#
# Each is a fast path and never load-bearing: with all three empty, the ladder
# is exactly the transcript reading it always was.
#
# Prints exactly one of:
#
#   dead      no tmux session, or the pane is back at a shell — Claude exited
#   starting  up, but Claude has not finished starting — often a trust prompt
#   fresh     up, but this conversation has not been written to yet
#   idle      the last turn finished; it is waiting for a human
#   working   busy right now
#   blocked   mid-turn but quiet — most often sitting on a permission prompt
#   unknown   the session store told us nothing usable
#
# The order matters. `idle` is tested before `working` because a turn that
# ended two seconds ago is idle, not busy — the file is fresh precisely
# BECAUSE Claude just stopped. Testing freshness first would make every
# just-finished session look busy for the whole grace period, which is exactly
# when a driver most wants to act on it.
cx_activity_state() {
  local alive="$1" shell="$2" uuid="$3" present="$4"
  local last_role="$5" last_stop="$6" quiet="$7"
  local claude_status="${8:-}" claude_kind="${9:-}" event="${10:-}" hooked="${11:-}"

  if [ "$alive" != true ] || [ "$shell" = true ]; then
    # A background session never had a tmux session to lose, and cx used to
    # call one dead while it worked. Claude's own status file is the only thing
    # that knows it is there. An interactive session with no tmux is dead
    # whatever its status file says: that file outlives a killed process.
    if [ "$claude_kind" = bg ]; then
      case "$claude_status" in
        idle)
          printf 'idle'
          return 0
          ;;
        busy)
          printf 'working'
          return 0
          ;;
        waiting)
          printf 'blocked'
          return 0
          ;;
      esac
    fi
    printf 'dead'
    return 0
  fi

  # Claude's word about its own process, when there is one to read. Every
  # value is exact: `waiting` is the permission prompt that a transcript can
  # only guess at after CX_IDLE_GRACE seconds of silence, and `busy` is a turn
  # in progress however long it has been quiet — a ten-minute test run is not
  # blocked, and before this, a driver escalated it as though it were.
  case "$claude_status" in
    waiting)
      printf 'blocked'
      return 0
      ;;
    busy)
      printf 'working'
      return 0
      ;;
    idle)
      # Waiting for input. It is `fresh` only when cx can SEE that the pinned
      # conversation has not started. With no pin, cx simply cannot find the
      # transcript, which says nothing about it — found on a real server, where
      # a 26-day-old session with no pin was reported as never having been
      # asked anything.
      if [ "$present" != true ] && [ -n "$uuid" ]; then
        printf 'fresh'
      else
        printf 'idle'
      fi
      return 0
      ;;
  esac

  # No status file: a hook's report, if cx started this session with hooks.
  # Still exact about what it saw, which is the reason it comes before any
  # reading of the transcript.
  case "$event" in
    working | blocked | idle | fresh)
      printf '%s' "$event"
      return 0
      ;;
  esac

  # Started with cx's hooks, running, and not a word from Claude: no status
  # file, no hook, no transcript. It has not finished starting, and the usual
  # reason it stays that way is a directory Claude has never trusted, where it
  # opens on "do you trust this folder?" with "No, exit" selected. Typing a
  # prompt there sends the Enter that picks it and ends the session — found on
  # a real server, by exactly that.
  #
  # Only with no transcript either. A conversation on disk proves Claude
  # started, whatever happened to cx's own state files (invariant 4).
  if [ "$hooked" = true ] && [ "$present" != true ]; then
    printf 'starting'
    return 0
  fi

  # No pinned conversation means cx has no way to find this session's
  # transcript — an old session from before pinning, or a store that has been
  # cleared. Not an error, just nothing to say.
  [ -n "$uuid" ] || {
    printf 'unknown'
    return 0
  }

  # Up, but this conversation has never been written to. Claude writes nothing
  # until its first exchange, so this covers both "started a moment ago" and
  # "started an hour ago and nobody has given it anything to do" — and, seen
  # for real, "sitting on the do-you-trust-this-folder prompt it shows the
  # first time it runs in a directory".
  #
  # cx does not try to tell those apart, and deliberately does not expire this
  # into `blocked`. Whether a session that is still `fresh` is stuck depends
  # on whether anything has been sent to it, which only the caller knows —
  # invariant 11. What cx reports is the fact plus how long it has been true;
  # the driver decides when that has gone on too long.
  [ "$present" = true ] || {
    printf 'fresh'
    return 0
  }

  if [ "$last_role" = assistant ] && [ "$last_stop" = end_turn ]; then
    printf 'idle'
    return 0
  fi

  case "$quiet" in
    '' | *[!0-9]*) ;; # unknown mtime: fall through to the message-based answer
    *)
      if [ "$quiet" -le "$CX_IDLE_GRACE" ]; then
        printf 'working'
        return 0
      fi
      ;;
  esac

  # Stale, and no main-thread message was found at all — the window observe
  # scanned held only sidechain and bookkeeping entries. Say so rather than
  # guessing.
  [ -n "$last_role" ] || {
    printf 'unknown'
    return 0
  }

  printf 'blocked'
}

# cx_activity_is_steerable STATE — may a nudge be sent to a session in STATE?
#
# `idle` is the obvious one: the turn finished and Claude is waiting.
#
# `fresh` is here because of how a session actually begins. Claude writes no
# transcript at all until its first exchange, so a session sitting at its
# prompt — ready, and wanting exactly the prompt a driver is about to send —
# looks the same as one still booting. Refusing here would break the primary
# flow, which is `open --detach` followed immediately by the task.
#
# `starting` is refused above all: a Claude still on its trust prompt exits on
# the Enter that submits a prompt, taking the session with it.
#
# The rest are refused: `working` would interleave with a turn in progress,
# `blocked` needs a human rather than more text, `dead` has nothing to type
# into, and `unknown` means we do not know enough to be typing at all.
cx_activity_is_steerable() {
  case "$1" in
    idle | fresh) return 0 ;;
    *) return 1 ;;
  esac
}

# cx_activity_color STATE — the state, colored for a terminal table.
cx_activity_color() {
  case "$1" in
    idle) printf '%s%s%s' "$C_GREEN" "$1" "$C_RESET" ;;
    working) printf '%s%s%s' "$C_CYAN" "$1" "$C_RESET" ;;
    blocked) printf '%s%s%s' "$C_YELLOW" "$1" "$C_RESET" ;;
    fresh) printf '%s%s%s' "$C_GREEN" "$1" "$C_RESET" ;;
    starting) printf '%s%s%s' "$C_DIM" "$1" "$C_RESET" ;;
    dead) printf '%s%s%s' "$C_RED" "$1" "$C_RESET" ;;
    *) printf '%s%s%s' "$C_DIM" "$1" "$C_RESET" ;;
  esac
}

# ---------------------------------------------------------------------------
# Reading an observe payload
# ---------------------------------------------------------------------------

# cx_activity_rows HOST FILE NOW — classify every session in one host's
# `observe` output. Prints one tab-separated row per session:
#
#   HOST \t TARGET \t STATE \t ATTACHED \t QUIET \t AGE
#
# ATTACHED is "true" or "false". QUIET is seconds since the transcript was
# last written and AGE seconds since the tmux session was created, each "-"
# when the fact is missing.
#
# This lives here rather than beside one command because two read it — cx peek
# and cx bar — and because the placeholder convention below is exactly the kind
# of detail that gets "simplified" back into a bug when it is written twice.
cx_activity_rows() {
  local host="$1" file="$2" now="$3"
  local target alive shell attached uuid present last_role last_stop mtime created
  local cstatus ckind event hooked quiet age state

  # Every field is emitted with a "-" placeholder when it is absent, and the
  # placeholder is not decoration. TAB IS IFS WHITESPACE: with IFS set to it,
  # `read` folds runs of tabs into one delimiter and drops empty fields, so a
  # row whose middle columns are blank silently shifts every later column left.
  # A session with no transcript has four blank columns in a row, which read
  # as one — and its creation time arrives in the variable meant for the last
  # message's role, so the session was classified from the wrong facts
  # entirely. Found by cx peek and cx nudge disagreeing about one session.
  #
  # The rows printed below keep the same convention for the same reason: their
  # last two columns are routinely empty.
  while IFS='	' read -r target alive shell attached uuid present last_role last_stop mtime created cstatus ckind event hooked; do
    [ -n "$target" ] || continue

    [ "$uuid" = - ] && uuid=""
    [ "$last_role" = - ] && last_role=""
    [ "$last_stop" = - ] && last_stop=""
    [ "$cstatus" = - ] && cstatus=""
    [ "$ckind" = - ] && ckind=""
    [ "$event" = - ] && event=""

    quiet=""
    age=""
    [ "$mtime" != - ] && quiet=$((now - mtime))
    [ "$created" != - ] && age=$((now - created))

    state=$(cx_activity_state "$alive" "$shell" "$uuid" "$present" \
      "$last_role" "$last_stop" "$quiet" "$cstatus" "$ckind" "$event" "$hooked")

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$host" "$target" "$state" "$attached" "${quiet:--}" "${age:--}"
  done <<EOF
$(jq -r '
    # "-" rather than "" for anything absent: see the note on IFS above.
    def f: if . == null or . == "" then "-" else tostring end;
    .sessions[]?
    | [ .target,
        (.tmux.alive         | tostring),
        (.tmux.shell         | tostring),
        (.tmux.attached      | tostring),
        (.transcript.uuid    | f),
        (.transcript.present | tostring),
        (.last.role          | f),
        (.last.stop_reason   | f),
        (.transcript.mtime   | f),
        (.tmux.created       | f),
        # From agent 0.4.0 on. An older agent leaves them out, and they then
        # become the same "-" as every other missing fact.
        (.claude.status      | f),
        (.claude.kind        | f),
        (.event.state        | f),
        (.hooks | tostring)
      ] | @tsv' "$file" 2>/dev/null)
EOF
}
