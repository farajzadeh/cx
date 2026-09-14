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
# shellcheck source=goal.sh
. "$CX_HOME/lib/cmd/goal.sh"

# _peek_fetch HOSTS TAIL DIR [UNIT] — one observe per host, in parallel, into DIR.
#
# The same shape as cx status: background jobs writing files, then a plain
# `wait`. `wait -n` is bash 4.3 and banned, so results are collected after all
# of them finish rather than as they arrive.
#
# UNIT narrows the question on the server. Filtering here instead "costs one
# round trip either way", which was the old defence of asking for --all, and it
# is true — but the round trip is 47 ms and the agent's work is seconds, and a
# peek at one session paid for every session on its host. An agent older than
# --unit answers "unknown option" with exit 3; that one case retries with the
# plain --all it understands, and the client-side filter in cmd_peek keeps the
# answer right either way.
_peek_fetch() {
  local hosts="$1" tail_n="$2" dir="$3" unit="${4:-}" h safe
  for h in $hosts; do
    safe=$(cx_sanitize "$h")
    (
      rc=0
      if [ -n "$unit" ]; then
        cx_agent "$h" observe --all --unit "$unit" --tail "$tail_n" \
          >"$dir/$safe.json" 2>/dev/null || rc=$?
        if [ "$rc" = 3 ]; then
          rc=0
          cx_agent "$h" observe --all --tail "$tail_n" >"$dir/$safe.json" 2>/dev/null || rc=$?
        fi
      else
        cx_agent "$h" observe --all --tail "$tail_n" >"$dir/$safe.json" 2>/dev/null || rc=$?
      fi
      [ "$rc" = 0 ] || printf '' >"$dir/$safe.fail"
    ) &
  done
  wait
}

# _peek_goal_fetch GOAL TAIL DIR — observe exactly a goal's members, into DIR.
#
# Prints the hosts involved, one per line. A member is stored as written: bare
# means the goal's own server, host:target another. Each host is asked only
# for its members, with --slug, so a driver pass costs the sessions it drives
# rather than every session anyone ever opened — and a member that is not
# running at all still comes back, as dead, instead of silently missing. An
# agent older than --slug gets --all, and the answer is cut down to the exact
# members here instead.
_peek_goal_fetch() {
  local name="$1" tail_n="$2" dir="$3" ghost gout members h m safe
  ghost=$(_goal_host) || return $?
  gout=$(_goal_agent "$ghost" show "$name") || return $?
  members=$(printf '%s' "$gout" | jq -r --arg g "$ghost" \
    '.members[]? | if test(":") then . else $g + ":" + . end' 2>/dev/null) || members=""

  local hosts
  hosts=$(printf '%s\n' "$members" | awk -F: 'NF > 1 { print $1 }' | sort -u)
  for h in $hosts; do
    safe=$(cx_sanitize "$h")
    (
      rc=0
      args=(observe --all)
      while IFS= read -r m; do
        [ -n "$m" ] && args=("${args[@]+"${args[@]}"}" --slug "$m")
      done <<EOF
$(printf '%s\n' "$members" | awk -F: -v h="$h" '$1 == h { sub(/^[^:]*:/, ""); print }')
EOF
      want=$(printf '%s\n' "$members" | awk -F: -v h="$h" '$1 == h { sub(/^[^:]*:/, ""); print }' | jq -Rsc 'split("\n") | map(select(length > 0))')
      cx_agent "$h" "${args[@]+"${args[@]}"}" --tail "$tail_n" >"$dir/$safe.raw" 2>/dev/null || rc=$?
      if [ "$rc" = 3 ]; then
        rc=0
        cx_agent "$h" observe --all --tail "$tail_n" >"$dir/$safe.raw" 2>/dev/null || rc=$?
      fi
      if [ "$rc" = 0 ]; then
        jq -c --argjson want "$want" \
          '.sessions |= map(select(.target as $t | $want | index($t)))' \
          "$dir/$safe.raw" >"$dir/$safe.json" 2>/dev/null || printf '' >"$dir/$safe.fail"
      else
        printf '' >"$dir/$safe.fail"
      fi
      rm -f "$dir/$safe.raw"
    ) &
  done
  wait
  printf '%s\n' "$hosts"
}

# _peek_rows HOST FILE NOW — one display row per session in a host's payload.
#
# The classification itself is cx_activity_rows in lib/activity.sh, shared with
# cx bar; what is left here is only how peek renders it. The agent reported
# facts and the state is decided on the client, because the grace period is the
# user's setting and because a pure function is the only part of this that a
# unit test can pin.
_peek_rows() {
  local host="$1" file="$2" now="$3" h target state attached quiet age

  cx_activity_rows "$host" "$file" "$now" |
    while IFS='	' read -r h target state attached quiet age; do
      # cx_activity_rows writes "-" for an absent number rather than an empty
      # column, so that a blank field cannot shift every later one left.
      [ "$quiet" = - ] && quiet=""
      [ "$age" = - ] && age=""

      printf '%s\t%s\t%s\t%s\t%s\n' \
        "$h" "$target" "$state" \
        "$([ "$attached" = true ] && printf 'you' || printf '—')" \
        "$(_peek_age "$quiet" "$age" "$state")"
    done
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
    fresh | starting) n="$age" ;;
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
  local target="" tail_n="$CX_PEEK_TAIL" show_all=0 goal=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        cat <<EOF
${C_BOLD}cx peek${C_RESET} — what each Claude session is doing right now

  cx peek                       every session on every server
  cx peek <host>:<project>[/<worktree>][@<label>]
  cx peek --json                the same, for a script or a driver agent
  cx peek --tail N              include the last N messages in --json
  cx peek --all                 list finished sessions too
  cx peek --goal <name>         just that goal's members, wherever they are

Reads each session's own conversation and reports one of:

  ${C_GREEN}idle${C_RESET}       the last turn finished — it is waiting for you
  ${C_CYAN}working${C_RESET}    busy right now
  ${C_YELLOW}blocked${C_RESET}    mid-turn but gone quiet — usually a permission prompt
  ${C_RED}dead${C_RESET}       Claude exited; the pane is back at a shell
  ${C_GREEN}fresh${C_RESET}      up, but this conversation has not started yet
  ${C_DIM}starting${C_RESET}   Claude has not finished starting — often the trust-this-folder
             prompt of a new directory; answer it with cx open
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
      --all) show_all=1 ;;
      --goal)
        [ $# -ge 2 ] || {
          err "--goal needs a goal name"
          return 3
        }
        goal="$2"
        shift
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

  if [ -n "$goal" ] && [ -n "$target" ]; then
    err "--goal and a target do not mix"
    hint "a goal names its own sessions: cx peek --goal $goal"
    return 3
  fi

  # A target narrows to one host; otherwise ask everyone.
  local hosts="" one_target=""
  if [ -n "$goal" ]; then
    : # hosts come from the goal's members, below
  elif [ -n "$target" ]; then
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

  # The table shows no messages, so it asks for none: a tail is what makes the
  # agent read the conversations of sessions that are not running.
  local fetch_tail=0
  [ "${CX_JSON:-0}" = 1 ] && fetch_tail="$tail_n"

  local tmp
  tmp=$(cx_mktempdir)
  cx_spinner_start "reading sessions"
  if [ -n "$goal" ]; then
    hosts=$(_peek_goal_fetch "$goal" "$fetch_tail" "$tmp") || {
      local grc=$?
      cx_spinner_stop
      rm -rf "$tmp"
      return "$grc"
    }
    # Every member is shown whatever its state: they are exactly what was
    # asked about, and a finished one is the thing a driver acts on.
    show_all=1
  else
    _peek_fetch "$hosts" "$fetch_tail" "$tmp" "$one_target"
  fi
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

  # Keep the tab icons fresh too. peek and `cx bar` ask the servers exactly
  # the same question, so an interactive peek is a free refresh of the cache
  # the per-window lookups read — but only when every host was asked, since a
  # narrowed run knows nothing about the sessions it did not look at and
  # writing it would erase them.
  if [ -z "$target" ] && [ -z "$goal" ]; then
    printf '%s' "$rows" | cx_state_write
  fi

  # Narrowing to one target happens here rather than in the query: the agent's
  # observe already accepts a single slug, but asking for --all and filtering
  # costs one round trip either way and keeps this path identical to the
  # unfiltered one.
  #
  # BOTH output paths must filter. They did not, once: the table narrowed and
  # --json did not, so `cx peek <target> --json` answered with every session on
  # the host. Nothing looked wrong — a caller that took .sessions[0], which is
  # what a driver naturally does, simply read a different session's transcript
  # and believed it. Found by a probe session reporting another project's work
  # as its own.
  if [ "${CX_JSON:-0}" = 1 ]; then
    _peek_json "$hosts" "$tmp" "$now" "$one_target"
    rm -rf "$tmp"
    return 0
  fi
  rm -rf "$tmp"

  if [ -n "$one_target" ]; then
    rows=$(printf '%s' "$rows" | awk -F'\t' -v t="$one_target" '$2 == t || index($2, t "@") == 1')
  fi

  rows=$(printf '%s' "$rows" | grep -v '^$' || true)

  # Finished sessions are counted, not listed, unless asked for. cx reports
  # every session it ever pinned that still has a conversation, because a
  # finished session is how a driver knows work needs reviving — and after a
  # few weeks that is most of the list: 23 of 26 on the server this was
  # written against, burying the three that were doing something. --json is
  # untouched, since a driver needs them, and naming a target shows everything
  # about it, since that is exactly what was asked for.
  local ndead=0
  if [ -z "$one_target" ] && [ "$show_all" != 1 ] && [ -n "$rows" ]; then
    ndead=$(printf '%s\n' "$rows" | awk -F'\t' '$3 == "dead"' | grep -c . || true)
    rows=$(printf '%s\n' "$rows" | awk -F'\t' '$3 != "dead"' | grep -v '^$' || true)
  fi

  if [ -n "$rows" ]; then
    {
      printf 'HOST\tSESSION\tSTATE\tWHO\tQUIET\n'
      printf '%s\n' "$rows" |
        while IFS='	' read -r h t s w q; do
          printf '%s\t%s\t%s\t%s\t%s\n' "$h" "$t" "$(cx_activity_color "$s")" "$w" "$q"
        done
    } | cx_table
    say ""
    if [ "${ndead:-0}" -gt 0 ]; then
      note "$ndead finished — list them with: cx peek --all"
    fi
    hint "send one a prompt with: cx nudge <target> \"...\""
  elif [ "${ndead:-0}" -gt 0 ]; then
    note "Nothing running. $ndead finished — list them with: cx peek --all"
    hint "revive one with: cx open -d <target>"
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
#
# Classified by cx_activity_rows — the same code the table and the status bar
# use — and joined back onto the agent's objects in one jq per host. This used
# to extract nine fields with nine jq processes per session, which on a server
# with two dozen sessions was most of sixteen seconds, and it is the call a
# driver makes on every pass.
_peek_json() {
  local hosts="$1" tmp="$2" now="$3" only="${4:-}" h safe
  local rows host target state attached quiet age steer joined
  {
    for h in $hosts; do
      safe=$(cx_sanitize "$h")
      [ -s "$tmp/$safe.json" ] || continue
      jq -e . "$tmp/$safe.json" >/dev/null 2>&1 || continue

      joined=""
      rows=$(cx_activity_rows "$h" "$tmp/$safe.json" "$now")
      while IFS='	' read -r host target state attached quiet age; do
        [ -n "$target" ] || continue
        steer=false
        cx_activity_is_steerable "$state" && steer=true
        joined="$joined$target	$state	$steer	$quiet	$age
"
      done <<EOF
$rows
EOF

      jq -c --arg h "$h" --arg only "$only" --arg rows "$joined" '
        ($rows
         | split("\n")
         | map(select(length > 0) | split("\t"))
         | map({key: .[0], value: {
             state:     .[1],
             steerable: (.[2] == "true"),
             quiet:     (if .[3] == "-" then null else (.[3] | tonumber) end),
             age:       (if .[4] == "-" then null else (.[4] | tonumber) end)
           }})
         | from_entries) as $r
        | .sessions[]?
        | select($only == "" or .target == $only or (.target | startswith($only + "@")))
        | . + {host: $h} + ($r[.target] // {state: "unknown", steerable: false, quiet: null, age: null})
        ' "$tmp/$safe.json" 2>/dev/null
    done
  } | jq -sc --argjson now "$now" --argjson grace "$CX_IDLE_GRACE" \
    '{observed_at: $now, idle_grace: $grace, sessions: .}'
}
