#!/usr/bin/env bash
# lib/cmd/peek.sh — `cx peek` — what is each session actually doing?
#
# `cx status` answers "what is running"; peek answers "which of these is
# waiting for me". The difference is worth a separate command because it is a
# different cost: status is one `tmux list-sessions` per host, while peek reads
# a transcript per session. Folding it into status would make the cheap
# question pay for the expensive one.
#
# One shot, always. There is deliberately no --follow: cx has no loop anywhere
# (see CLAUDE.md invariant 11), and the caller that wants to poll — a person,
# or a driver agent — already has one.
#
# Never cached, for the same reason cx status is not: a thirty-second-old
# answer to "is it stuck" is worse than no answer.

# shellcheck source=../target.sh
. "$CX_HOME/lib/target.sh"
# shellcheck source=../activity.sh
. "$CX_HOME/lib/activity.sh"

# _peek_fetch HOSTS TAIL DIR — one observe per host, in parallel, into DIR.
#
# The same shape as cx status: background jobs writing files, then a plain
# `wait`. `wait -n` is bash 4.3 and banned, so results are collected after all
# of them finish rather than as they arrive.
_peek_fetch() {
  local hosts="$1" tail_n="$2" dir="$3" h safe
  for h in $hosts; do
    safe=$(cx_sanitize "$h")
    (
      cx_agent "$h" observe --all --tail "$tail_n" >"$dir/$safe.json" 2>/dev/null ||
        printf '' >"$dir/$safe.fail"
    ) &
  done
  wait
}

# _peek_rows HOST FILE NOW — classified rows for one host's payload.
#
# The agent reported facts; the state is decided here, by lib/activity.sh,
# because the grace period is the user's setting and because a pure function is
# the only part of this that a unit test can pin.
_peek_rows() {
  local host="$1" file="$2" now="$3"
  local line target alive shell uuid present last_role last_stop mtime created
  local quiet age state attached

  # Every field is emitted with a "-" placeholder when it is absent, and the
  # placeholder is not decoration. TAB IS IFS WHITESPACE: with IFS set to it,
  # `read` folds runs of tabs into one delimiter and drops empty fields, so a
  # row whose middle columns are blank silently shifts every later column left.
  # A session with no transcript has four blank columns in a row, which read
  # as one — and its creation time arrives in the variable meant for the last
  # message's role, so the session was classified from the wrong facts
  # entirely. Found by cx peek and cx nudge disagreeing about one session.
  while IFS='	' read -r target alive shell attached uuid present last_role last_stop mtime created; do
    [ -n "$target" ] || continue

    [ "$uuid" = - ] && uuid=""
    [ "$last_role" = - ] && last_role=""
    [ "$last_stop" = - ] && last_stop=""

    quiet=""
    age=""
    [ "$mtime" != - ] && quiet=$((now - mtime))
    [ "$created" != - ] && age=$((now - created))

    state=$(cx_activity_state "$alive" "$shell" "$uuid" "$present" \
      "$last_role" "$last_stop" "$quiet")

    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$host" "$target" "$state" \
      "$([ "$attached" = true ] && printf 'you' || printf '—')" \
      "$(_peek_age "$quiet" "$age" "$state")"
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
        (.tmux.created       | f)
      ] | @tsv' "$file" 2>/dev/null)
EOF
}

# _peek_age QUIET AGE STATE — the "for how long" column.
#
# For a session with a conversation this is how long the transcript has been
# quiet. A `fresh` session has no transcript, so it reports how long it has
# been up instead — which is the number that says whether "no conversation
# yet" means "just started" or "nobody has given it anything to do".
_peek_age() {
  local quiet="$1" age="$2" state="$3" n=""
  case "$state" in
    fresh) n="$age" ;;
    dead) n="" ;;
    *) n="$quiet" ;;
  esac
  [ -n "$n" ] || {
    printf '—'
    return 0
  }
  cx_human_age "$n"
}

cmd_peek() {
  local target="" tail_n="$CX_PEEK_TAIL"

  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        cat <<EOF
${C_BOLD}cx peek${C_RESET} — what each Claude session is doing right now

  cx peek                       every session on every server
  cx peek <host>:<project>[/<worktree>][@<label>]
  cx peek --json                the same, for a script or a driver agent
  cx peek --tail N              include the last N messages in --json

Reads each session's own conversation and reports one of:

  ${C_GREEN}idle${C_RESET}       the last turn finished — it is waiting for you
  ${C_CYAN}working${C_RESET}    busy right now
  ${C_YELLOW}blocked${C_RESET}    mid-turn but gone quiet — usually a permission prompt
  ${C_RED}dead${C_RESET}       Claude exited; the pane is back at a shell
  ${C_GREEN}fresh${C_RESET}      up, but this conversation has not started yet
  ${C_DIM}unknown${C_RESET}    no pinned conversation, or nothing readable

QUIET is how long the conversation has been silent. A session counts as
working until it has been quiet for ${C_BOLD}\$CX_IDLE_GRACE${C_RESET} seconds (currently $CX_IDLE_GRACE), after
which a turn that never finished is called blocked instead.

This always queries the servers — a cached answer to "is it stuck" would
defeat the point — and it reads a transcript per session, so it is slower than
cx status. Use status for "what is running", peek for "what needs me".

Related: cx nudge (send it a prompt), cx open -d (start one without attaching)
EOF
        return 0
        ;;
      --tail)
        shift
        tail_n="${1:-$CX_PEEK_TAIL}"
        ;;
      -*)
        err "unknown option: $1"
        return 3
        ;;
      *) [ -z "$target" ] && target="$1" ;;
    esac
    shift
  done

  case "$tail_n" in
    '' | *[!0-9]*)
      err "--tail wants a number"
      return 3
      ;;
  esac

  # A target narrows to one host; otherwise ask everyone.
  local hosts="" one_target=""
  if [ -n "$target" ]; then
    cx_target_resolve "$target" || return $?
    hosts="$CX_T_HOST"
    one_target=$(cx_target_unit_str)
  else
    hosts=$(cx_hosts_list)
    if [ -z "$hosts" ]; then
      note "No servers configured."
      hint "add one with: cx host add"
      return 0
    fi
  fi

  local tmp
  tmp=$(cx_mktempdir)
  cx_spinner_start "reading sessions"
  _peek_fetch "$hosts" "$tail_n" "$tmp"
  cx_spinner_stop

  local now h safe rows="" failed="" stale=""
  now=$(cx_now)

  for h in $hosts; do
    safe=$(cx_sanitize "$h")
    if [ -s "$tmp/$safe.json" ] && jq -e . "$tmp/$safe.json" >/dev/null 2>&1; then
      rows="$rows$(_peek_rows "$h" "$tmp/$safe.json" "$now")
"
    elif [ -e "$tmp/$safe.fail" ] || [ ! -s "$tmp/$safe.json" ]; then
      # An agent that predates observe answers "unknown command", which is not
      # JSON — indistinguishable here from an unreachable host, so check.
      if cx_agent "$h" version >/dev/null 2>&1; then
        stale="$stale $h"
      else
        failed="$failed $h"
      fi
    fi
  done

  if [ "${CX_JSON:-0}" = 1 ]; then
    _peek_json "$hosts" "$tmp" "$now"
    rm -rf "$tmp"
    return 0
  fi
  rm -rf "$tmp"

  # Narrowing to one target happens here rather than in the query: the agent's
  # observe already accepts a single slug, but asking for --all and filtering
  # costs one round trip either way and keeps this path identical to the
  # unfiltered one.
  if [ -n "$one_target" ]; then
    rows=$(printf '%s' "$rows" | awk -F'\t' -v t="$one_target" '$2 == t || index($2, t "@") == 1')
  fi

  rows=$(printf '%s' "$rows" | grep -v '^$' || true)

  if [ -n "$rows" ]; then
    {
      printf 'HOST\tSESSION\tSTATE\tWHO\tQUIET\n'
      printf '%s\n' "$rows" |
        while IFS='	' read -r h t s w q; do
          printf '%s\t%s\t%s\t%s\t%s\n' "$h" "$t" "$(cx_activity_color "$s")" "$w" "$q"
        done
    } | cx_table
    say ""
    hint "send one a prompt with: cx nudge <target> \"...\""
  else
    note "No sessions to report."
    hint "start one with: cx open -d <host>:<project>"
  fi

  local x
  for x in $stale; do
    warn "$x runs an agent too old to observe — cx provision $x"
  done
  for x in $failed; do
    warn "$x unreachable — its sessions are not shown"
  done
}

# _peek_json — the driver's view: the agent's facts with the derived state
# folded in, so a caller never has to reimplement the ladder.
_peek_json() {
  local hosts="$1" tmp="$2" now="$3" h safe
  {
    for h in $hosts; do
      safe=$(cx_sanitize "$h")
      [ -s "$tmp/$safe.json" ] || continue
      jq -e . "$tmp/$safe.json" >/dev/null 2>&1 || continue
      jq -c --arg h "$h" '.sessions[]? | . + {host: $h}' "$tmp/$safe.json" 2>/dev/null
    done
  } | while IFS= read -r line; do
    [ -n "$line" ] || continue
    _peek_json_one "$line" "$now"
  done | jq -sc --argjson now "$now" --argjson grace "$CX_IDLE_GRACE" \
    '{observed_at: $now, idle_grace: $grace, sessions: .}'
}

_peek_json_one() {
  local line="$1" now="$2"
  local alive shell uuid present last_role last_stop mtime created quiet="" age="" state
  alive=$(printf '%s' "$line" | jq -r '.tmux.alive | tostring')
  shell=$(printf '%s' "$line" | jq -r '.tmux.shell | tostring')
  attached=$(printf '%s' "$line" | jq -r '.tmux.attached | tostring')
  uuid=$(printf '%s' "$line" | jq -r '.transcript.uuid // ""')
  present=$(printf '%s' "$line" | jq -r '.transcript.present | tostring')
  last_role=$(printf '%s' "$line" | jq -r '.last.role // ""')
  last_stop=$(printf '%s' "$line" | jq -r '.last.stop_reason // ""')
  mtime=$(printf '%s' "$line" | jq -r '.transcript.mtime // ""')
  created=$(printf '%s' "$line" | jq -r '.tmux.created // ""')

  [ -n "$mtime" ] && quiet=$((now - mtime))
  [ -n "$created" ] && age=$((now - created))

  state=$(cx_activity_state "$alive" "$shell" "$uuid" "$present" \
    "$last_role" "$last_stop" "$quiet")

  printf '%s' "$line" | jq -c \
    --arg state "$state" --arg quiet "$quiet" --arg age "$age" \
    --argjson steerable "$(cx_activity_is_steerable "$state" && printf true || printf false)" '
    . + {
      state:     $state,
      steerable: $steerable,
      quiet:     (if $quiet == "" then null else ($quiet | tonumber) end),
      age:       (if $age   == "" then null else ($age   | tonumber) end)
    }'
}
