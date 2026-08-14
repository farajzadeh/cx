#!/usr/bin/env bash
# lib/cmd/status.sh — `cx status` — live sessions across every server.
#
# Deliberately NOT cached by default. "Is it running right now" is the entire
# question, and a 30-second-old answer to it is worse than useless.

# shellcheck source=../projects.sh
. "$CX_HOME/lib/projects.sh"

cmd_status() {
  case "${1:-}" in
    -h | --help)
      cat <<EOF
${C_BOLD}cx status${C_RESET} — Claude sessions running right now

  cx status

Shows live tmux sessions on every server, whether anyone is attached, and how
long each has been running. This always queries the servers: a cached answer
to "is it running" would defeat the point.

PROJECT is the target to reattach with, including a worktree if the session is
in one. SESSION is the label, or — for a project's default session. Together
they are what you type after the host:

  HOST   PROJECT       SESSION    ->  cx open web1:api@review
  web1   api           review
  web1   api/authfix   —          ->  cx open web1:api/authfix

MODE is the permission mode the session was started with — ${C_BOLD}acceptEdits${C_RESET},
${C_BOLD}plan${C_RESET}, and so on, with bypassPermissions shown as ${C_BOLD}no-perms${C_RESET}. Blank means
Claude's default. A live session's permission mode cannot be changed and is
invisible from inside it, so this is the only place it shows.
EOF
      return 0
      ;;
  esac

  local hosts
  hosts=$(cx_hosts_list)
  if [ -z "$hosts" ]; then
    note "No servers configured."
    hint "add one with: cx host add"
    return 0
  fi

  local tmp h safe
  tmp=$(cx_mktempdir)

  for h in $hosts; do
    safe=$(cx_sanitize "$h")
    (cx_agent "$h" sessions >"$tmp/$safe.json" 2>/dev/null || printf '' >"$tmp/$safe.fail") &
  done
  wait

  local rows="" any=0 failed=""
  for h in $hosts; do
    safe=$(cx_sanitize "$h")
    if [ -s "$tmp/$safe.json" ] && jq -e . "$tmp/$safe.json" >/dev/null 2>&1; then
      local n
      n=$(jq -r '.sessions | length' "$tmp/$safe.json" 2>/dev/null || printf 0)
      [ "${n:-0}" -gt 0 ] && any=1
      # `.target` is what the agent reports from 0.2.0 on: the full
      # project[/worktree] with the project name recovered from the registry.
      # Falling back to .project keeps this working against an older agent.
      rows="$rows$(jq -r --arg h "$h" --argjson now "$(cx_now)" '
        .sessions[]?
        | [ $h,
            ((.target // .project) | sub("@.*$"; "")),
            (.label // "—"),
            # bypassPermissions gets the blunt name: it is the one worth
            # spotting across a screenful of sessions. `.dangerous` alone is
            # what a pre-0.3.0 agent reports.
            (if   .mode == "bypassPermissions" then "no-perms"
             elif .mode != null                then .mode
             elif .dangerous                   then "no-perms"
             else "" end),
            (if .attached then "attached" else "detached" end),
            (if .created == null then "—"
             else ($now - .created) as $a
               | if   $a < 60    then "\($a)s"
                 elif $a < 3600  then "\(($a / 60)    | floor)m"
                 elif $a < 86400 then "\(($a / 3600)  | floor)h"
                 else                 "\(($a / 86400) | floor)d"
                 end
             end)
          ] | @tsv' "$tmp/$safe.json")
"
    else
      failed="$failed $h"
    fi
  done
  rm -rf "$tmp"

  if [ "$any" = 1 ]; then
    {
      printf 'HOST\tPROJECT\tSESSION\tMODE\tSTATE\tUPTIME\n'
      printf '%s' "$rows" | grep -v '^$'
    } | cx_table
    say ""
    hint "attach with: cx open <host>:<project>[@<session>]"
  else
    note "No live sessions."
    hint "start one with: cx open <host>:<project>"
  fi

  if [ -n "$failed" ]; then
    say ""
    for h in $failed; do
      warn "$h unreachable — its sessions are not shown"
    done
  fi
}
