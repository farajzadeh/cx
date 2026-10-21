#!/usr/bin/env bash
# lib/cmd/rc.sh — `cx rc` — a project's own Remote Control setting.
#
# Remote Control is decided when a session starts, by the first of: the
# command line, the project's own setting, the host's `#cx:remote_control=`
# line, CX_REMOTE_CONTROL. This command reads and writes the second. It lives
# in the server's registry, not in this machine's config, so a laptop and an
# always-on host running cx web see the same answer (invariant 5: the server
# records what cannot be derived, and a preference cannot be).

# shellcheck source=../target.sh
. "$CX_HOME/lib/target.sh"

# _rc_default HOST — what a project with no setting of its own gets on HOST.
_rc_default() {
  local def
  def=$(cx_host_meta "$1" remote_control 2>/dev/null) || def=""
  case "$def" in
    0 | 1) printf '%s' "$def" ;;
    *) printf '%s' "${CX_REMOTE_CONTROL:-0}" ;;
  esac
}

cmd_rc() {
  local sub="" target=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        cat <<EOF
${C_BOLD}cx rc${C_RESET} — whether a project's sessions start with Remote Control

  cx rc                                 every project's setting, and what it means
  cx rc <host>                          one server's projects
  cx rc on      <host>:<project>        always, for this project
  cx rc off     <host>:<project>        never, for this project
  cx rc default <host>:<project>        follow the host and CX_REMOTE_CONTROL again

Remote Control puts a session on claude.ai/code and in the Claude app, named
after its target, where you can read it, send it messages, approve its
prompts and interrupt it. Whether a new session gets it is the first of:

  1. --remote-control or --no-remote-control on cx open, new or wt add
  2. this setting, kept in the project's server's registry
  3. #cx:remote_control=0|1 in the host's file (cx host edit <host>)
  4. CX_REMOTE_CONTROL in ~/.config/cx/config (default 0)

It applies when a session starts. A running session keeps what it started
with: cx stop it and open it again. cx status and cx peek show it as ${C_BOLD}rc${C_RESET}.

Related: cx open --remote-control, cx peek --json (each session's link)
EOF
        return 0
        ;;
      -*)
        err "unknown option: $1"
        return 3
        ;;
      *)
        if [ -z "$sub" ]; then
          sub="$1"
        elif [ -z "$target" ]; then
          target="$1"
        else
          err "unexpected argument: $1"
          return 3
        fi
        ;;
    esac
    shift
  done

  case "$sub" in
    on | off | default) _rc_set "$sub" "$target" ;;
    *)
      # Anything else is a host to list, or nothing for every host.
      [ -z "$target" ] || {
        err "unknown subcommand: $sub"
        hint "usage: cx rc [on|off|default <host>:<project>]"
        return 3
      }
      _rc_list "$sub"
      ;;
  esac
}

# _rc_set VALUE TARGET
_rc_set() {
  local val="$1" target="$2" out
  [ -n "$target" ] || {
    err "which project?"
    hint "usage: cx rc $val <host>:<project>"
    return 3
  }
  cx_target_resolve "$target" || return $?
  # The setting belongs to the project, and a worktree or a label is not one:
  # saying so beats quietly setting it on the project they belong to.
  if [ -n "$CX_T_WORKTREE" ] || [ -n "$CX_T_SESSION" ]; then
    err "Remote Control is set per project, not per worktree or session"
    hint "for the whole project: cx rc $val $CX_T_HOST:$CX_T_PROJECT"
    hint "for one session, when it starts: cx open --remote-control $(cx_target_str)"
    return 3
  fi
  cx_agent_supports "$CX_T_HOST" "Remote Control" 0.8.0 || return 1

  out=$(cx_agent "$CX_T_HOST" rc set "$CX_T_PROJECT" "$val") || return $?
  # The setting is part of what cx ls --json reports for the project.
  cx_cache_invalidate "$CX_T_HOST"

  if [ "${CX_JSON:-0}" = 1 ]; then
    printf '%s\n' "$out" | jq -c --arg h "$CX_T_HOST" '{host: $h} + .'
    return 0
  fi
  case "$val" in
    on) say "$CX_T_HOST:$CX_T_PROJECT: new sessions start with Remote Control" ;;
    off) say "$CX_T_HOST:$CX_T_PROJECT: new sessions start without Remote Control" ;;
    default)
      say "$CX_T_HOST:$CX_T_PROJECT: follows the default again ($([ "$(_rc_default "$CX_T_HOST")" = 1 ] && printf on || printf off) on $CX_T_HOST)"
      ;;
  esac
  hint "a session already running keeps what it started with: cx stop, then cx open"
}

# _rc_list [HOST] — the setting per project, and what a new session gets.
_rc_list() {
  local only="$1" hosts h safe tmp
  if [ -n "$only" ]; then
    cx_host_exists "$only" || {
      err "unknown host: $only"
      return 2
    }
    hosts="$only"
  else
    hosts=$(cx_hosts_list)
  fi
  [ -n "$hosts" ] || {
    note "No servers configured."
    hint "add one with: cx host add"
    return 0
  }

  tmp=$(cx_mktempdir)
  for h in $hosts; do
    safe=$(cx_sanitize "$h")
    (cx_agent "$h" rc ls >"$tmp/$safe.json" 2>/dev/null || printf '' >"$tmp/$safe.fail") &
  done
  wait

  local rows="" failed="" def
  for h in $hosts; do
    safe=$(cx_sanitize "$h")
    if jq -e '.projects' "$tmp/$safe.json" >/dev/null 2>&1; then
      def=$(_rc_default "$h")
      rows="$rows$(jq -c --arg h "$h" --argjson def "$def" '
        .projects[] | {host: $h, project: .name, setting: .remote_control,
          remote_control: (if .remote_control == null then $def == 1 else .remote_control end)}' \
        "$tmp/$safe.json")
"
    else
      failed="$failed $h"
    fi
  done
  rm -rf "$tmp"

  if [ "${CX_JSON:-0}" = 1 ]; then
    printf '%s' "$rows" | jq -sc '{projects: .}'
    return 0
  fi

  if [ -n "$(printf '%s' "$rows" | tr -d '\n')" ]; then
    {
      printf 'HOST\tPROJECT\tSETTING\tNEW SESSIONS\n'
      printf '%s' "$rows" | jq -r '
        [ .host, .project,
          (if .setting == true then "on" elif .setting == false then "off" else "default" end),
          (if .remote_control then "rc" else "—" end)
        ] | @tsv'
    } | cx_table
    say ""
    hint "change one with: cx rc on|off|default <host>:<project>"
  else
    note "No projects."
  fi
  for h in $failed; do
    warn "$h: no answer, or an agent older than 0.8.0 — cx provision $h"
  done
  return 0
}
