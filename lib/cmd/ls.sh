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

Worktrees are listed indented under the project they belong to, as
<project>/<worktree> — the same form you pass to cx open.

Columns:
  SESSIONS   Claude conversations recorded for that directory
  ACTIVE     when the most recent one was last touched
  LIVE       ● a session is running now; ●N several are
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
        # A count only when there is more than one, so the common case stays a
        # single quiet dot. tmux_count is absent on pre-0.2.0 agents.
        def live:
          if   (.tmux_count // 0) > 1 then "●" + ((.tmux_count) | tostring)
          elif .tmux_live             then "●"
          else                             ""
          end;
        def dirt: if . == true then "*" else "" end;

        . as $p

        # The project itself.
        | ( [ $p.host, $p.name, ($p.branch // "—") ]
            + (if $git then [ ($p.dirty | dirt) ] else [] end)
            + [ (if $p.sessions == null then "?" else ($p.sessions | tostring) end),
                ($p.last_active | ago),
                ($p | live),
                ($p.repo | short) ]
            | @tsv ),

        # Then its worktrees, indented under it. The name stays fully
        # qualified rather than being abbreviated to the leaf, so a row can be
        # copied straight back onto the command line as a target.
          ( $p.worktrees[]?
            | [ "", ("  " + $p.name + "/" + .name), (.branch // "—") ]
              + (if $git then [ (.dirty | dirt) ] else [] end)
              + [ (if .sessions == null then "?" else (.sessions | tostring) end),
                  (.last_active | ago),
                  (. | live),
                  "" ]
            | @tsv )'
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
