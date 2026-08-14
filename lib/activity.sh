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
#
# ALIVE/SHELL/PRESENT are the strings "true" or "false"; UUID and the LAST_*
# fields are empty when unknown; QUIET is seconds since the transcript was last
# written, or empty.
#
# Prints exactly one of:
#
#   dead      no tmux session, or the pane is back at a shell — Claude exited
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

  [ "$alive" = true ] || {
    printf 'dead'
    return 0
  }
  [ "$shell" = true ] && {
    printf 'dead'
    return 0
  }

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
    dead) printf '%s%s%s' "$C_RED" "$1" "$C_RESET" ;;
    *) printf '%s%s%s' "$C_DIM" "$1" "$C_RESET" ;;
  esac
}
