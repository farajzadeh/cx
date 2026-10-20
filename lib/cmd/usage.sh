#!/usr/bin/env bash
# lib/cmd/usage.sh — `cx usage` — how much of Claude each server's account has
# used.
#
# Each server is one Claude subscription, so the question is per server: how
# close its account is to its limits, and where its tokens went. Both answers
# come from what Claude Code writes down on the server by itself — the limits
# it last reported (its status line, its own copy of its usage screen) and the
# token counts in its transcripts. cx reads no login and calls nothing at
# Anthropic.
#
# Never cached, like peek: the agent keeps its own cache of what it has read of
# the transcripts (invariant 4 applies there), which makes asking again cheap,
# and a client cache in front of it would only make the limits staler.

# shellcheck source=../target.sh
. "$CX_HOME/lib/target.sh"

# The agent version that has `usage`. One place, next to the feature it gates.
CX_USAGE_MIN_AGENT=0.7.0

# _usage_fetch HOSTS DAYS DIR — one agent call per host, in parallel, into DIR.
#
# Each host leaves either HOST.json (the agent's answer) or HOST.err (one line
# saying why not). The version is asked first so an agent that predates usage
# is reported as too old rather than as "unknown command", which says nothing
# about re-provisioning. ssh exits 255 when it cannot connect at all, which is
# how unreachable is told apart from an agent that is not installed.
_usage_fetch() {
  local hosts="$1" days="$2" dir="$3" h safe
  for h in $hosts; do
    safe=$(cx_sanitize "$h")
    (
      rc=0
      ver=$(cx_agent "$h" version 2>/dev/null) || rc=$?
      if [ -z "$ver" ]; then
        if [ "$rc" = 255 ]; then
          printf 'unreachable\n' >"$dir/$safe.err"
        else
          printf 'the cx agent is not installed\n' >"$dir/$safe.err"
        fi
        exit 0
      fi
      if ! cx_agent_supports "$h" "cx usage" "$CX_USAGE_MIN_AGENT" "$ver" 2>/dev/null; then
        printf 'the cx agent is too old for cx usage (it reports %s; this needs %s)\n' \
          "$ver" "$CX_USAGE_MIN_AGENT" >"$dir/$safe.err"
        exit 0
      fi
      rc=0
      cx_agent "$h" usage --days "$days" >"$dir/$safe.json" 2>/dev/null || rc=$?
      if [ "$rc" != 0 ] || ! jq -e 'type == "object"' "$dir/$safe.json" >/dev/null 2>&1; then
        rm -f "$dir/$safe.json"
        if [ "$rc" = 255 ]; then
          printf 'unreachable\n' >"$dir/$safe.err"
        else
          printf 'the cx agent failed (exit %s)\n' "$rc" >"$dir/$safe.err"
        fi
      fi
    ) &
  done
  wait
}

# _usage_json HOSTS DAYS DIR — the answer for a program: the agent's object per
# host, with host, ok and error in front. A host that did not answer is still
# listed, with every figure null, so a caller can say which one and why.
_usage_json() {
  local hosts="$1" days="$2" dir="$3" h safe
  {
    for h in $hosts; do
      safe=$(cx_sanitize "$h")
      if [ -s "$dir/$safe.json" ]; then
        jq -c --arg h "$h" '{host: $h, ok: true, error: null} + .' "$dir/$safe.json" 2>/dev/null
      else
        jq -nc --arg h "$h" --arg e "$(cat "$dir/$safe.err" 2>/dev/null || printf 'no answer')" \
          '{host: $h, ok: false, error: $e, observed_at: null, since: null,
            limits: null, days: null, projects: null}'
      fi
    done
  } | jq -sc --argjson now "$(cx_now)" --argjson days "$days" \
    '{observed_at: $now, days: $days, hosts: .}'
}

# Figures for a person: 1.3B, 1.2M, 340k, 980. Cache reads on a busy server
# run past a billion a day.
_USAGE_DEFS='
  def tok: if . >= 1000000000 then ((. / 100000000 | floor) / 10 | tostring) + "B"
    elif . >= 1000000 then ((. / 100000 | floor) / 10 | tostring) + "M"
    elif . >= 1000 then (. / 1000 | floor | tostring) + "k"
    else (floor | tostring) end;
  def fresh: .input + .output + .cache_write;'

# The limits as one line, the way the tmux bar shows them: "5h 23% ↻ 21:50 ·
# 7d 41% ↻ Thu 00:00", then how old the reading is. A window that has reset
# since is left out, because its figure describes nothing now. strflocaltime is
# tried because it is newer than jq 1.5.
_USAGE_LIMITS_LINE_JQ='
  def pct: (. + 0.5 | floor | tostring) + "%";
  def win($label; $fmt):
    if . == null or (.resets_at != null and .resets_at <= $now) then empty
    else $label + " " + (.pct | pct)
      + (if .resets_at == null then ""
         else (try (" ↻ " + (.resets_at | strflocaltime($fmt))) catch "") end)
    end;
  .limits as $l
  | if $l == null then "limits: not reported yet"
    else [($l.five_hour | win("5h"; "%H:%M")), ($l.seven_day | win("7d"; "%a %H:%M"))] as $p
      | (if ($p | length) == 0 then "limits: no reading since they last reset"
         else $p | join(" · ") end)
        + " (as of \($now - $l.at | if . < 60 then "just now"
            elif . < 3600 then "\(. / 60 | floor)m ago"
            elif . < 86400 then "\(. / 3600 | floor)h ago"
            else "\(. / 86400 | floor)d ago" end))"
    end'

# _usage_show HOST FILE NOW — one host, for a person: the limits, the last week
# day by day, and where the tokens went. NEW TOKENS leaves out cache reads,
# which repeat the conversation so far on every step and would drown the rest.
_usage_show() {
  local h="$1" f="$2" now="$3" rows
  hdr "$h"
  say "  $(jq -r --argjson now "$now" "$_USAGE_LIMITS_LINE_JQ" "$f" 2>/dev/null)"
  rows=$(jq -r "$_USAGE_DEFS"'
    .days[-7:][]? | [.date, (fresh | tok), (.cache_read | tok), (.messages | tostring)] | @tsv' \
    "$f" 2>/dev/null) || rows=""
  say ""
  if [ -n "$rows" ]; then
    {
      printf 'DAY\tNEW TOKENS\tCACHE READ\tMESSAGES\n'
      printf '%s\n' "$rows"
    } | cx_table | sed 's/^/  /'
  else
    note "  No Claude messages since $(jq -r '.since // "?"' "$f" 2>/dev/null)."
    return 0
  fi
  rows=$(jq -r "$_USAGE_DEFS"'
    .projects[:5][]? | [(.project // "(no project)"), (fresh | tok), (.messages | tostring)] | @tsv' \
    "$f" 2>/dev/null) || rows=""
  if [ -n "$rows" ]; then
    say ""
    {
      printf 'PROJECT\tNEW TOKENS\tMESSAGES\n'
      printf '%s\n' "$rows"
    } | cx_table | sed 's/^/  /'
  fi
}

cmd_usage() {
  local hosts="" days=30 h

  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        cat <<EOF
${C_BOLD}cx usage${C_RESET} — how much of Claude each server's account has used

  cx usage                      every server
  cx usage <host>...            just these
  cx usage --days N             tokens over the last N days (1-90, default 30)
  cx usage --json               the same, for a program

Each server is signed in to its own Claude account, so this is per server:

  ${C_BOLD}limits${C_RESET}   the five-hour and weekly limits, as Claude last reported them —
           its status line in a cx session, or its own copy of its /usage
           screen — with when they reset and how old the reading is
  ${C_BOLD}tokens${C_RESET}   per day and per project, counted from Claude's transcripts on
           the server; subagents included, each message once

Days are UTC dates. NEW TOKENS is input, output and cache writes; cache reads
(the conversation so far, re-read on every step) are shown apart.

Nothing here reads a login or asks Anthropic: it is all what Claude Code wrote
down on the server by itself. The first run on a server reads every transcript
of the window, which takes a while on a busy one; the agent remembers what it
has read, so later runs read only what is new.

Needs agent $CX_USAGE_MIN_AGENT or newer: cx provision <host>.

Related: cx peek (what each session is doing), cx bar --setup (limits in tmux)
EOF
        return 0
        ;;
      --days)
        [ $# -ge 2 ] || {
          err "--days needs a number"
          return 3
        }
        days="$2"
        shift
        ;;
      -*)
        err "unknown option: $1"
        return 3
        ;;
      *) hosts="$hosts $1" ;;
    esac
    shift
  done

  case "$days" in
    '' | *[!0-9]* | ???*)
      err "--days wants a number from 1 to 90"
      return 3
      ;;
  esac
  days=$((10#$days))
  if [ "$days" -lt 1 ] || [ "$days" -gt 90 ]; then
    err "--days wants a number from 1 to 90"
    return 3
  fi

  if [ -n "$hosts" ]; then
    for h in $hosts; do
      if ! cx_host_exists "$h"; then
        err "unknown host: $h"
        local known
        known=$(cx_hosts_list | tr '\n' ' ')
        if [ -n "$known" ]; then
          hint "configured hosts: $known"
        else
          hint "add one with: cx host add"
        fi
        return 2
      fi
    done
  else
    hosts=$(cx_hosts_list)
    if [ -z "$hosts" ]; then
      if [ "${CX_JSON:-0}" = 1 ]; then
        jq -nc --argjson now "$(cx_now)" --argjson days "$days" '{observed_at: $now, days: $days, hosts: []}'
        return 0
      fi
      note "No servers configured."
      hint "add one with: cx host add"
      return 0
    fi
  fi

  local tmp
  tmp=$(cx_mktempdir)
  cx_spinner_start "reading usage"
  _usage_fetch "$hosts" "$days" "$tmp"
  cx_spinner_stop

  if [ "${CX_JSON:-0}" = 1 ]; then
    _usage_json "$hosts" "$days" "$tmp"
    rm -rf "$tmp"
    return 0
  fi

  local now safe failed=""
  now=$(cx_now)
  for h in $hosts; do
    safe=$(cx_sanitize "$h")
    if [ -s "$tmp/$safe.json" ]; then
      _usage_show "$h" "$tmp/$safe.json" "$now"
    else
      failed="$failed $h"
    fi
  done
  for h in $failed; do
    safe=$(cx_sanitize "$h")
    case "$(cat "$tmp/$safe.err" 2>/dev/null)" in
      *"too old"*) warn "$h runs an agent too old for cx usage — cx provision $h" ;;
      *"not installed"*) warn "$h has no cx agent — cx provision $h" ;;
      unreachable) warn "$h unreachable — its usage is not shown" ;;
      *) warn "$h: $(cat "$tmp/$safe.err" 2>/dev/null || printf 'no answer')" ;;
    esac
  done
  rm -rf "$tmp"
  return 0
}
