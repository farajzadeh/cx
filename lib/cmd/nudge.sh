#!/usr/bin/env bash
# lib/cmd/nudge.sh — `cx nudge` — send a prompt to a session already running.
#
# The counterpart to `cx ask`. Ask starts its own claude and gets an answer
# back; nudge types into the conversation that is already open, and the answer
# appears in that session rather than here. Use ask for a question, nudge to
# move work along.
#
# It checks first. A prompt typed into a session that is mid-turn interleaves
# with what Claude is already doing, so nudge looks at the session's state and
# declines rather than making a mess. Declining is a normal outcome, not an
# error: it exits 0 and says why, because the caller — usually a driver agent
# in a loop — needs to tell "busy, come back" apart from "this is broken".

# shellcheck source=../target.sh
. "$CX_HOME/lib/target.sh"
# shellcheck source=../activity.sh
. "$CX_HOME/lib/activity.sh"

cmd_nudge() {
  local target="" prompt="" force=0

  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        cat <<EOF
${C_BOLD}cx nudge${C_RESET} — send a prompt to a session that is already running

  cx nudge <target> "what to do next"
  echo "what to do next" | cx nudge <target>
  cx nudge <target> --force "..."     send it even if the session is busy

The prompt is typed into that session's Claude, exactly as if you had attached
and typed it. The reply appears in the session — attach with cx open to read
it, or cx peek to see when the turn has finished.

Nudge declines, without erroring, when the session is not ready for input:

  ${C_CYAN}working${C_RESET}   mid-turn — wait for it to finish
  ${C_YELLOW}blocked${C_RESET}   quiet mid-turn, usually a permission prompt only you can answer
  ${C_RED}dead${C_RESET}      Claude has exited — restart it with cx open -d
  attached  you have it open; cx will not type over your shoulder

${C_BOLD}--force${C_RESET} overrides all of those. It is the right call for "stop what you are
doing and do this instead"; it is the wrong call in a loop.

The prompt travels over stdin, so quotes, \$(...), backticks and newlines all
arrive intact and there is no length limit.

Related: cx peek (what state is it in), cx ask (a question, answered here),
         cx open -d (start a session without attaching)
EOF
        return 0
        ;;
      --force) force=1 ;;
      -*)
        err "unknown option: $1"
        return 3
        ;;
      *)
        if [ -z "$target" ]; then target="$1"; else prompt="${prompt:+$prompt }$1"; fi
        ;;
    esac
    shift
  done

  [ -n "$target" ] || {
    err "no target given"
    hint 'usage: cx nudge <host>:<project>[@<label>] "what to do next"'
    hint "see what is running with: cx peek"
    return 3
  }

  cx_target_resolve "$target" || return $?

  if [ -z "$prompt" ]; then
    if [ -t 0 ]; then
      err "no prompt given"
      hint "usage: cx nudge $(cx_target_str) \"what to do next\""
      return 3
    fi
    prompt=$(cat)
  fi
  [ -n "$prompt" ] || {
    err "empty prompt"
    return 3
  }

  local ver=""
  ver=$(cx_agent "$CX_T_HOST" version 2>/dev/null) || true
  if [ -z "$ver" ]; then
    err "the cx agent is not installed on $CX_T_HOST"
    hint "install it with: cx provision $CX_T_HOST"
    return 1
  fi
  cx_agent_observe_ok "$CX_T_HOST" "$ver" || return 1

  # Look before typing. The state depends on CX_IDLE_GRACE, which is the
  # user's setting, so it is decided here rather than on the server — see
  # lib/activity.sh.
  local state="" obs=""
  cx_target_args
  obs=$(cx_agent "$CX_T_HOST" observe "$CX_T_PROJECT" \
    "${CX_T_ARGS[@]+"${CX_T_ARGS[@]}"}" --tail 0 2>/dev/null) || obs=""

  if [ -n "$obs" ]; then
    state=$(_nudge_state "$obs")
  fi

  if [ -n "$state" ] && [ "$force" != 1 ] && ! cx_activity_is_steerable "$state"; then
    _nudge_report "$(cx_target_str)" false "$state" "$state"
    return 0
  fi

  local out=""
  local args=""
  [ "$force" = 1 ] && args=--force
  # The prompt travels on stdin; only the target and flags are arguments.
  local opts
  opts=$(cx_ssh_opts)
  # shellcheck disable=SC2086
  out=$(printf '%s' "$prompt" |
    ssh $opts "$CX_T_HOST" \
      "$CX_AGENT_PATH$(cx_remote_quote nudge "$CX_T_PROJECT" \
        "${CX_T_ARGS[@]+"${CX_T_ARGS[@]}"}" $args)") || return $?

  local sent reason
  sent=$(printf '%s' "$out" | jq -r '.sent' 2>/dev/null) || sent=""
  reason=$(printf '%s' "$out" | jq -r '.reason // empty' 2>/dev/null) || reason=""

  _nudge_report "$(cx_target_str)" "${sent:-false}" "${reason:-$state}" "$state"
}

# _nudge_state OBSERVE_JSON — classify the one session observe reported on.
_nudge_state() {
  local obs="$1" now alive shell uuid present last_role last_stop mtime
  local quiet=""
  now=$(cx_now)
  alive=$(printf '%s' "$obs" | jq -r '.sessions[0].tmux.alive | tostring' 2>/dev/null) || return 1
  [ -n "$alive" ] && [ "$alive" != null ] || return 1
  shell=$(printf '%s' "$obs" | jq -r '.sessions[0].tmux.shell | tostring')
  uuid=$(printf '%s' "$obs" | jq -r '.sessions[0].transcript.uuid // ""')
  present=$(printf '%s' "$obs" | jq -r '.sessions[0].transcript.present | tostring')
  last_role=$(printf '%s' "$obs" | jq -r '.sessions[0].last.role // ""')
  last_stop=$(printf '%s' "$obs" | jq -r '.sessions[0].last.stop_reason // ""')
  mtime=$(printf '%s' "$obs" | jq -r '.sessions[0].transcript.mtime // ""')
  [ -n "$mtime" ] && quiet=$((now - mtime))
  cx_activity_state "$alive" "$shell" "$uuid" "$present" \
    "$last_role" "$last_stop" "$quiet"
}

# _nudge_report TARGET SENT REASON STATE
_nudge_report() {
  local target="$1" sent="$2" reason="$3" state="$4"

  if [ "${CX_JSON:-0}" = 1 ]; then
    jq -nc --arg target "$target" --arg reason "$reason" --arg state "$state" \
      --argjson sent "$sent" '{
        target: $target,
        sent:   $sent,
        state:  (if $state  == "" then null else $state  end),
        reason: (if $sent or $reason == "" then null else $reason end)
      }'
    return 0
  fi

  if [ "$sent" = true ]; then
    say "sent to $target"
    hint "watch for the reply with: cx peek $target"
    return 0
  fi

  case "$reason" in
    working)
      note "$target is mid-turn — not sent."
      hint "wait for it, or override with: cx nudge $target --force \"...\""
      ;;
    blocked)
      note "$target has gone quiet mid-turn — not sent."
      hint "it is probably waiting on a prompt only you can answer:"
      hint "  cx open $target"
      ;;
    dead)
      note "$target is not running — not sent."
      hint "start it again with: cx open -d $target"
      ;;
    attached)
      note "$target is open in front of you — not sent."
      hint "type it there, or override with: cx nudge $target --force \"...\""
      ;;
    fresh)
      note "$target has no conversation yet — not sent."
      hint "check on it with: cx peek $target"
      ;;
    *)
      note "$target did not accept the prompt${reason:+ ($reason)}."
      hint "see what it is doing with: cx peek $target"
      ;;
  esac
  return 0
}
