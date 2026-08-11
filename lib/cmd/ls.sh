#!/usr/bin/env bash
# lib/cmd/ls.sh — `cx ls` — every project on every server.

# shellcheck source=../projects.sh
. "$CX_HOME/lib/projects.sh"

# _ls_relative EPOCH — "3m", "2h", "5d" or "—".
_ls_relative() {
  local t="${1:-}" now age
  [ -n "$t" ] && [ "$t" != null ] && [ "$t" != 0 ] || {
    printf '—'
    return
  }
  now=$(cx_now)
  age=$((now - t))
  [ "$age" -lt 0 ] && age=0
  cx_human_age "$age"
}

cmd_ls() {
  local want_git="" only_host="" raw

  while [ $# -gt 0 ]; do
    case "$1" in
      --git) want_git="--git" ;;
      -h | --help)
        cat <<EOF
${C_BOLD}cx ls${C_RESET} — list projects across servers

  cx ls                 every project on every server
  cx ls <host>          one server
  cx ls --git           include working-tree dirty state (slower on big repos)
  cx ls --json          machine-readable

Columns:
  SESSIONS   Claude conversations recorded for that project
  ACTIVE     when the most recent one was last touched
  LIVE       a tmux session is running right now
EOF
        return 0
        ;;
      -*)
        err "unknown option: $1"
        return 3
        ;;
      *) only_host="$1" ;;
    esac
    shift
  done

  if [ -n "$only_host" ] && ! cx_host_exists "$only_host"; then
    err "unknown host: $only_host"
    return 2
  fi

  local hosts
  hosts=$(cx_hosts_list)
  if [ -z "$hosts" ]; then
    note "No servers configured."
    hint "add one with: cx host add"
    return 0
  fi

  cx_spinner_start "querying servers"
  if [ -n "$only_host" ]; then
    if ! raw=$(cx_projects_get "$only_host" "$want_git"); then
      raw=$(jq -nc --arg h "$only_host" '{host:$h, ok:false, error:"unreachable or agent not installed"}')
    fi
  else
    raw=$(cx_projects_fanout $want_git)
  fi
  cx_spinner_stop

  if [ "${CX_JSON:-0}" = 1 ]; then
    printf '%s\n' "$raw" | jq -s '{
      servers: map({host, ok, error: (.error // null)}),
      projects: [ .[] | select(.ok) as $h | .projects[]? | . + {host: $h.host} ]
    }'
    return 0
  fi

  local projects failed
  projects=$(printf '%s\n' "$raw" | jq -c 'select(.ok) | . as $h | .projects[]? | . + {host: $h.host}')
  failed=$(printf '%s\n' "$raw" | jq -r 'select(.ok | not) | .host')

  if [ -z "$projects" ] && [ -z "$failed" ]; then
    note "No projects yet."
    hint "create one with: cx new <host>:<name>"
    return 0
  fi

  if [ -n "$projects" ]; then
    # ONE jq for the whole table.
    #
    # The obvious shape — a shell loop extracting each field — costs about
    # seven jq processes per project, which dominated the runtime of a warm
    # `cx ls` far more than the network ever did. Formatting in jq keeps a
    # cached listing at process-startup cost regardless of project count.
    {
      if [ -n "$want_git" ]; then
        printf 'HOST\tPROJECT\tBRANCH\t \tSESSIONS\tACTIVE\tLIVE\tREPO\n'
      else
        printf 'HOST\tPROJECT\tBRANCH\tSESSIONS\tACTIVE\tLIVE\tREPO\n'
      fi
      printf '%s\n' "$projects" | jq -r --argjson now "$(cx_now)" \
        --argjson git "$([ -n "$want_git" ] && printf true || printf false)" '
        def ago:
          if . == null or . == 0 then "—"
          else ($now - .) as $a
            | if   $a < 60    then "\($a)s"
              elif $a < 3600  then "\(($a / 60)     | floor)m"
              elif $a < 86400 then "\(($a / 3600)   | floor)h"
              else                 "\(($a / 86400)  | floor)d"
              end
          end;
        # Shorten the common forges for display; --json keeps the full value.
        def short:
          if . == null then "—"
          else sub("^git@github\\.com:"; "gh:")
             | sub("^https://github\\.com/"; "gh:")
             | sub("^git@gitlab\\.com:"; "gl:")
             | sub("^https://gitlab\\.com/"; "gl:")
             | sub("\\.git$"; "")
          end;
        [ .host,
          .name,
          (.branch // "—")
        ]
        + (if $git then [ (if .dirty == true then "*" else "" end) ] else [] end)
        + [ (if .sessions == null then "?" else (.sessions | tostring) end),
            (.last_active | ago),
            (if .tmux_live then "●" else "" end),
            (.repo | short)
          ]
        | @tsv'
    } | cx_table
  fi

  # A partial view must announce itself. Silently omitting a server's projects
  # would make `cx ls` look authoritative while being wrong.
  if [ -n "$failed" ]; then
    say ""
    printf '%s\n' "$failed" | while IFS= read -r h; do
      [ -n "$h" ] || continue
      warn "$h unreachable — its projects are not shown"
    done
    hint "diagnose with: cx host test <host>"
  fi
}
