#!/usr/bin/env bash
# lib/cmd/goal.sh — `cx goal` — what a set of sessions is trying to achieve.
#
# A goal is a definition of done plus the sessions working towards it. It is
# the one thing cx stores that cannot be derived from anything else, which is
# why the servers hold it (invariant 5) rather than this machine.
#
# cx does not decide whether the definition of done is met. It stores the
# text, tracks who is working on it, and records what happened; judging it is
# the driver's job (invariant 11). That division is what makes pause work
# without a daemon: nothing here is running, so pausing is just a field, and
# the driver stops because it re-reads the goal every time round.

# shellcheck source=../target.sh
. "$CX_HOME/lib/target.sh"
# shellcheck source=../projects.sh
. "$CX_HOME/lib/projects.sh"

# _goal_host — which server holds goals when no target says.
#
# A goal lives on exactly one host. With several configured and no default,
# there is no sensible guess, so say so rather than picking.
_goal_host() {
  local h="${CX_GOAL_HOST:-${CX_DEFAULT_HOST:-}}" hosts n
  if [ -n "$h" ]; then
    printf '%s' "$h"
    return 0
  fi
  hosts=$(cx_hosts_list)
  n=$(printf '%s\n' "$hosts" | grep -c . || true)
  if [ "${n:-0}" = 1 ]; then
    printf '%s' "$hosts"
    return 0
  fi
  err "which server should hold this goal?"
  hint "name one with: cx goal --host <host> ..."
  hint "or set CX_DEFAULT_HOST in ~/.config/cx/config"
  return 3
}

# _goal_agent HOST ARGS... — call the agent, gating on version first.
_goal_agent() {
  local host="$1"
  shift
  local ver=""
  ver=$(cx_agent "$host" version 2>/dev/null) || true
  if [ -z "$ver" ]; then
    err "the cx agent is not installed on $host"
    hint "install it with: cx provision $host"
    return 1
  fi
  cx_agent_goals_ok "$host" "$ver" || return 1
  cx_agent "$host" goal "$@"
}

# _goal_render GOAL_JSON HOST — one goal, for a person.
_goal_render() {
  local g="$1" host="$2" state members
  state=$(printf '%s' "$g" | jq -r '.state')
  hdr "$(printf '%s' "$g" | jq -r '.name')  [$state]"
  printf '%s' "$g" | jq -r '.dod' | while IFS= read -r l; do say "  $l"; done
  say ""
  members=$(printf '%s' "$g" | jq -r --arg h "$host" \
    '.members[]? | if test(":") then . else $h + ":" + . end')
  if [ -n "$members" ]; then
    say "  Members:"
    printf '%s\n' "$members" | while IFS= read -r m; do say "    $m"; done
  else
    note "  No members yet — add one with: cx goal member add <name> <target>"
  fi
  local revs
  revs=$(printf '%s' "$g" | jq -r '.revisions | length')
  [ "${revs:-0}" -gt 0 ] && note "  $revs revision(s) — see cx goal show <name> --json"
  return 0
}

cmd_goal() {
  local sub="" host=""
  local args=()

  # --host is pulled out wherever it appears and everything else is kept in
  # order, so `cx goal --host web1 show auth` and `cx goal show auth --host
  # web1` mean the same thing — matching how bin/cx treats the global flags.
  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        cat <<EOF
${C_BOLD}cx goal${C_RESET} — what a set of sessions is trying to achieve

  cx goal new <name> "definition of done" [--member <target>]...
  cx goal ls [--state active|paused|done]
  cx goal show <name>
  cx goal dod <name> "the new definition of done"
  cx goal member add|rm <name> <target>
  cx goal pause <name> | resume <name> | done <name>
  cx goal log <name> "what happened" [--event E] [--target T]
  cx goal rm <name>

A goal is a definition of done, plus the sessions working towards it. It is
stored on the server, so it outlives this terminal and is the same goal seen
from any machine you use.

One goal can cover several sessions — an implementation worktree and the
session testing it, say — and they need not be on the same server:

  cx goal new auth "the auth tests pass and a PR is open" \\
      --member web1:api/authfix@impl \\
      --member web2:api@tests

${C_BOLD}Changing your mind is expected.${C_RESET} cx goal dod replaces the text and keeps the
old one in the goal's history, so what a session was asked for at the time is
still recoverable afterwards.

${C_BOLD}cx goal pause${C_RESET} stops the driver, not the work. Nothing is killed: no session
is touched, no process is signalled. A driver re-reads the goal each time
round and stops when it is not active — which is also why nothing can keep
driving a goal you have paused.

cx does not decide when a goal is done — you or your driver does, with
cx goal done. It stores the intent and reports the facts; see cx peek.

Related: cx peek (what each session is doing), cx nudge (steer one)
EOF
        return 0
        ;;
      --host)
        shift
        host="${1:-}"
        ;;
      *) args=("${args[@]+"${args[@]}"}" "$1") ;;
    esac
    shift
  done

  set -- "${args[@]+"${args[@]}"}"
  sub="${1:-}"
  [ -n "$sub" ] || {
    err "no subcommand given"
    hint "usage: cx goal new|ls|show|dod|member|pause|resume|done|log|rm"
    return 3
  }
  shift

  [ -n "$host" ] || host=$(_goal_host) || return $?

  case "$sub" in
    ls | list)
      local out=""
      out=$(_goal_agent "$host" ls "$@") || return $?
      if [ "${CX_JSON:-0}" = 1 ]; then
        printf '%s\n' "$out" | jq -c --arg h "$host" '. + {host: $h}'
        return 0
      fi
      local n
      n=$(printf '%s' "$out" | jq -r '.goals | length')
      if [ "${n:-0}" = 0 ]; then
        note "No goals on $host."
        hint 'create one with: cx goal new <name> "definition of done"'
        return 0
      fi
      {
        printf 'GOAL\tSTATE\tMEMBERS\tDEFINITION OF DONE\n'
        printf '%s' "$out" | jq -r '
          .goals[]
          | [ .name,
              .state,
              (.members | length | tostring),
              (.dod | split("\n")[0] | if length > 56 then .[0:53] + "..." else . end)
            ] | @tsv'
      } | cx_table
      say ""
      hint "see one in full with: cx goal show <name>"
      ;;

    show)
      local name="${1:-}" out=""
      [ -n "$name" ] || {
        err "which goal?"
        return 3
      }
      out=$(_goal_agent "$host" show "$name") || return $?
      if [ "${CX_JSON:-0}" = 1 ]; then
        printf '%s\n' "$out" | jq -c --arg h "$host" '. + {host: $h}'
        return 0
      fi
      _goal_render "$out" "$host"
      ;;

    new)
      local name="" dod="" members=""
      name="${1:-}"
      shift 2>/dev/null || true
      while [ $# -gt 0 ]; do
        case "$1" in
          --member)
            shift
            members="$members --member $(printf '%s' "${1:-}")"
            ;;
          *) dod="${dod:+$dod }$1" ;;
        esac
        shift
      done
      [ -n "$name" ] || {
        err "no goal name given"
        hint 'usage: cx goal new <name> "definition of done"'
        return 3
      }
      if [ -z "$dod" ]; then
        if [ -t 0 ]; then
          err "no definition of done given"
          hint "usage: cx goal new $name \"what finished looks like\""
          hint "or pipe it in: cat dod.md | cx goal new $name"
          return 3
        fi
        dod=$(cat)
      fi
      [ -n "$dod" ] || {
        err "empty definition of done"
        return 3
      }
      _goal_write "$host" "$dod" new "$name" $members || return $?
      ;;

    dod)
      local name="${1:-}" dod=""
      shift 2>/dev/null || true
      dod="$*"
      [ -n "$name" ] || {
        err "which goal?"
        return 3
      }
      if [ -z "$dod" ]; then
        [ -t 0 ] && {
          err "no new definition of done given"
          hint "usage: cx goal dod $name \"what finished looks like now\""
          return 3
        }
        dod=$(cat)
      fi
      [ -n "$dod" ] || {
        err "empty definition of done"
        return 3
      }
      _goal_write "$host" "$dod" dod "$name" || return $?
      ;;

    log)
      local name="${1:-}" text="" event=note target=""
      shift 2>/dev/null || true
      while [ $# -gt 0 ]; do
        case "$1" in
          --event)
            shift
            event="${1:-note}"
            ;;
          --target)
            shift
            target="${1:-}"
            ;;
          *) text="${text:+$text }$1" ;;
        esac
        shift
      done
      [ -n "$name" ] || {
        err "which goal?"
        return 3
      }
      [ -n "$text" ] || { [ -t 0 ] || text=$(cat); }
      local targs=""
      [ -n "$target" ] && targs="--target $target"
      _goal_write "$host" "$text" log "$name" --event "$event" $targs || return $?
      ;;

    member)
      local op="${1:-}" name="${2:-}" target="${3:-}" out=""
      [ -n "$op" ] && [ -n "$name" ] && [ -n "$target" ] || {
        err "usage: cx goal member add|rm <name> <target>"
        return 3
      }
      # A member given as a bare project is qualified with its host, so a goal
      # always records which server the work is on even when the user did not
      # have to type it.
      if [ "$op" = add ] && cx_target_split "$target" >/dev/null 2>&1; then
        if [ -n "$CX_T_HOST" ] && [ "$CX_T_HOST" != "$host" ]; then
          target=$(cx_target_str)
        else
          target=$(cx_target_unit_str)
        fi
      fi
      out=$(_goal_agent "$host" member "$op" "$name" "$target") || return $?
      cx_cache_invalidate "$host"
      if [ "${CX_JSON:-0}" = 1 ]; then
        printf '%s\n' "$out" | jq -c --arg h "$host" '. + {host: $h}'
      else
        _goal_render "$out" "$host"
      fi
      ;;

    pause | resume | done)
      local name="${1:-}" want="" out=""
      [ -n "$name" ] || {
        err "which goal?"
        return 3
      }
      case "$sub" in
        pause) want=paused ;;
        resume) want=active ;;
        # Quoted because `done` is a shell keyword: bare, it reads as the end
        # of a loop rather than as a value.
        done) want="done" ;;
      esac
      out=$(_goal_agent "$host" state "$name" "$want") || return $?
      if [ "${CX_JSON:-0}" = 1 ]; then
        printf '%s\n' "$out" | jq -c --arg h "$host" '. + {host: $h}'
        return 0
      fi
      case "$sub" in
        pause)
          say "paused $name"
          hint "no session was touched — the work is exactly where you left it"
          hint "pick it up again with: cx goal resume $name"
          ;;
        resume) say "resumed $name" ;;
        done)
          say "marked $name done"
          hint "its sessions are still running — end them with: cx stop <target>"
          ;;
      esac
      ;;

    rm)
      local name="${1:-}" out=""
      [ -n "$name" ] || {
        err "which goal?"
        return 3
      }
      if [ "${CX_ASSUME_YES:-0}" != 1 ]; then
        cx_confirm "Remove the goal '$name' from $host?" || {
          note "Left alone."
          return 0
        }
      fi
      out=$(_goal_agent "$host" rm "$name") || return $?
      if [ "${CX_JSON:-0}" = 1 ]; then
        printf '%s\n' "$out" | jq -c --arg h "$host" '. + {host: $h}'
      else
        say "removed $name"
        hint "its sessions are untouched"
      fi
      ;;

    *)
      err "unknown subcommand: $sub"
      hint "usage: cx goal new|ls|show|dod|member|pause|resume|done|log|rm"
      return 3
      ;;
  esac
}

# _goal_write HOST TEXT ARGS... — a goal call whose payload travels on stdin.
#
# The definition of done is a paragraph of the user's prose. Sending it over
# stdin rather than argv means it never passes through a shell on either side,
# so quotes, $(...) and newlines all arrive exactly as typed — the same reason
# cx ask does it.
_goal_write() {
  local host="$1" text="$2"
  shift 2

  local ver=""
  ver=$(cx_agent "$host" version 2>/dev/null) || true
  if [ -z "$ver" ]; then
    err "the cx agent is not installed on $host"
    hint "install it with: cx provision $host"
    return 1
  fi
  cx_agent_goals_ok "$host" "$ver" || return 1

  local opts out=""
  opts=$(cx_ssh_opts)
  # shellcheck disable=SC2086
  out=$(printf '%s' "$text" |
    ssh $opts "$host" \
      "$CX_AGENT_PATH$(cx_remote_quote goal "$@")") || return $?

  if [ "${CX_JSON:-0}" = 1 ]; then
    printf '%s\n' "$out" | jq -c --arg h "$host" '. + {host: $h}'
    return 0
  fi
  _goal_render "$out" "$host"
}
