#!/usr/bin/env bash
# lib/cmd/ls.sh — `cx ls` — every project on every server.

# shellcheck source=../projects.sh
. "$CX_HOME/lib/projects.sh"
# shellcheck source=../filter.sh
. "$CX_HOME/lib/filter.sh"

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

_ls_usage() {
  cat <<EOF
${C_BOLD}cx ls${C_RESET} — list projects across servers

  cx ls                   every project on every server
  cx ls <host>            one server
  cx ls <pattern>         only what matches (see PATTERNS)
  cx ls <host> <pattern>  both
  cx ls --git             include working-tree dirty state (slower on big repos)
  cx ls --json            machine-readable

Worktrees are listed indented under the project they belong to, as
<project>/<worktree> — the same form you pass to cx open.

${C_BOLD}FILTERS${C_RESET} (they combine: a row must pass every one)
  -f, --filter PATTERN   match host, project, worktree, branch or repo
      --host H[,H...]    only these servers (repeatable); others are not contacted
      --live             a session is running in it now
      --active DUR       touched within DUR, e.g. 30m, 2h, 7d, 2w
      --idle DUR         not touched for DUR — never touched counts as idle
      --dirty            uncommitted changes (implies --git, so never cached)
      --no-worktrees     projects only

${C_BOLD}LAYOUT${C_RESET}
      --group host|none  a heading per server instead of a HOST column
      --sort KEY         name, active (most recent first), sessions (most
                         first), host, or none (the servers' own order)

  Defaults for --group and --sort come from CX_LS_GROUP and CX_LS_SORT.
  --json honours every filter and --sort, keeps its usual shape, and ignores
  --group: grouping is a way of drawing a table, not a different answer.

${C_BOLD}PATTERNS${C_RESET}
  Case-insensitive. Plain text matches anywhere (${C_BOLD}auth${C_RESET} finds authfix); with a
  ${C_BOLD}*${C_RESET} it is a glob over the whole field (${C_BOLD}api*${C_RESET}, ${C_BOLD}*-fix${C_RESET}). The target forms
  web1:api and api/authfix are fields too, so ${C_BOLD}'web1:*'${C_RESET} works.

  A project that matches keeps all its worktrees. A project that does not,
  but has a worktree that does, is shown as the heading for just that
  worktree. The same goes for --live, --active, --idle and --dirty.

  A single word is a host if a host by that name is configured, and a
  pattern otherwise. To search for text that is also a host's name, use -f.

${C_BOLD}COLUMNS${C_RESET}
  SESSIONS   Claude conversations recorded for that directory
  ACTIVE     when the most recent one was last touched
  LIVE       ● a session is running now; ●N several are

  --sort active and --sort sessions count a project's worktrees as part of
  it: a project whose worktree you used a minute ago is recent.
EOF
}

# _ls_check_choice NAME VALUE CHOICES... — is VALUE one of CHOICES?
_ls_check_choice() {
  local name="$1" value="$2" c
  shift 2
  for c in "$@"; do
    [ "$value" = "$c" ] && return 0
  done
  err "$name must be one of: $* (got: $value)"
  return 1
}

# _ls_not_a_host HOST_POS POS1 — after an empty result, the one surprise the
# positional rule can spring: a mistyped host is silently a pattern. Say so
# rather than just "nothing matches".
_ls_not_a_host() {
  [ "$1" = 0 ] && [ -n "$2" ] || return 0
  hint "'$2' is not a configured host, so it was taken as a pattern — hosts: cx host ls"
}

cmd_ls() {
  local want_git="" raw
  local pattern="" hosts_arg="" live=false dirty=false no_wt=false
  local idle=-1 active=-1 d
  local group="" sort="" pos1="" pos2="" npos=0 host_pos=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --git) want_git="--git" ;;
      -f | --filter)
        [ $# -ge 2 ] || {
          err "$1 needs a pattern"
          return 3
        }
        shift
        [ -z "$pattern" ] || {
          err "only one pattern at a time (have: $pattern)"
          return 3
        }
        pattern="$1"
        ;;
      --host)
        [ $# -ge 2 ] || {
          err "--host needs a host"
          return 3
        }
        shift
        hosts_arg="$hosts_arg,$1"
        ;;
      --live) live=true ;;
      --dirty)
        dirty=true
        want_git="--git"
        ;;
      --no-worktrees) no_wt=true ;;
      --active | --idle)
        [ $# -ge 2 ] || {
          err "$1 needs a duration, e.g. 30m, 2h or 7d"
          return 3
        }
        d=$(cx_duration_secs "$2") || {
          err "$1: not a duration: $2 (try 30m, 2h, 7d)"
          return 3
        }
        if [ "$1" = --active ]; then active="$d"; else idle="$d"; fi
        shift
        ;;
      --group)
        [ $# -ge 2 ] || {
          err "--group needs host or none"
          return 3
        }
        shift
        _ls_check_choice --group "$1" host none || return 3
        group="$1"
        ;;
      --sort)
        [ $# -ge 2 ] || {
          err "--sort needs a key"
          return 3
        }
        shift
        _ls_check_choice --sort "$1" name active sessions host none || return 3
        sort="$1"
        ;;
      -h | --help)
        _ls_usage
        return 0
        ;;
      -*)
        err "unknown option: $1"
        return 3
        ;;
      *)
        npos=$((npos + 1))
        case "$npos" in
          1) pos1="$1" ;;
          2) pos2="$1" ;;
          *)
            err "too many arguments: $1"
            hint "usage: cx ls [host] [pattern]"
            return 3
            ;;
        esac
        ;;
    esac
    shift
  done

  # Flags beat configuration, and a bad configured value is a config error
  # (78) rather than a usage one — the command line was fine.
  if [ -z "$group" ]; then
    group="${CX_LS_GROUP:-none}"
    _ls_check_choice CX_LS_GROUP "$group" host none || return 78
  fi
  if [ -z "$sort" ]; then
    sort="${CX_LS_SORT:-none}"
    _ls_check_choice CX_LS_SORT "$sort" name active sessions host none || return 78
  fi

  # The positional host-or-pattern rule. `cx ls web1` has always meant the
  # server web1, and must keep meaning it; so a first word that is a
  # configured host is a host, and anything else is a pattern. The obvious
  # "simplification" — always a pattern, since a host's name matches its own
  # projects anyway — is wrong twice over: it would stop narrowing the
  # fan-out (so `cx ls web1` would connect to every server and warn about
  # every unreachable one), and a pattern also matches project names, so
  # `cx ls web1` would start listing web2's project `web1-mirror`.
  if [ -n "$pos1" ]; then
    if cx_host_exists "$pos1"; then
      hosts_arg="$hosts_arg,$pos1"
      host_pos=1
      if [ -n "$pos2" ]; then
        [ -z "$pattern" ] || {
          err "two patterns: $pos2 and -f $pattern"
          return 3
        }
        pattern="$pos2"
      fi
    else
      [ -z "$pos2" ] || {
        err "unknown host: $pos1"
        hint "usage: cx ls [host] [pattern] — list hosts with: cx host ls"
        return 2
      }
      [ -z "$pattern" ] || {
        err "two patterns: $pos1 and -f $pattern"
        return 3
      }
      pattern="$pos1"
    fi
  fi

  local hosts h scoped=""
  hosts=$(cx_hosts_list)
  if [ -z "$hosts" ]; then
    note "No servers configured."
    hint "add one with: cx host add"
    return 0
  fi

  if [ -n "$hosts_arg" ]; then
    for h in $(cx_filter_split_list "$hosts_arg"); do
      if ! cx_host_exists "$h"; then
        err "unknown host: $h"
        return 2
      fi
      case " $scoped " in
        *" $h "*) ;;
        *) scoped="$scoped $h" ;;
      esac
    done
  fi

  cx_spinner_start "querying servers"
  # shellcheck disable=SC2086  # $scoped is a list of validated aliases
  set -- $scoped
  if [ $# -eq 1 ]; then
    # One host takes the direct path it always has, error text included.
    if ! raw=$(cx_projects_get "$1" "$want_git"); then
      raw=$(jq -nc --arg h "$1" '{host:$h, ok:false, error:"unreachable or agent not installed"}')
    fi
  else
    raw=$(cx_projects_fanout $want_git "$@")
  fi
  cx_spinner_stop

  local filtering=false
  if [ -n "$pattern" ] || [ "$live" = true ] || [ "$dirty" = true ] ||
    [ "$idle" -ge 0 ] || [ "$active" -ge 0 ] || [ "$no_wt" = true ]; then
    filtering=true
  fi

  # Every jq below sees the same variables, so the filter means the same
  # thing in the JSON and in the table.
  local git=false
  [ -n "$want_git" ] && git=true
  local jargs
  jargs=(--arg pat "$pattern" --argjson live "$live" --argjson dirty "$dirty"
    --argjson nowt "$no_wt" --argjson idle "$idle" --argjson active "$active"
    --arg sort "$sort" --arg group "$group" --argjson git "$git"
    --argjson now "$(cx_now)" --arg bold "$C_BOLD" --arg reset "$C_RESET")

  if [ "${CX_JSON:-0}" = 1 ]; then
    printf '%s\n' "$raw" | jq -s "${jargs[@]+"${jargs[@]}"}" "$CX_FILTER_JQ$_LS_SELECT"'
      {
        servers: map({host, ok, error: (.error // null)}),
        projects: projects
      }'
    return 0
  fi

  # One jq for the failures and the count of everything before filtering —
  # the latter only to tell "no projects at all" from "none match".
  local failed total
  failed=$(printf '%s\n' "$raw" | jq -rs '
    ([ .[] | select(.ok) | .projects[]? ] | length),
    (.[] | select(.ok | not) | .host)')
  total=$(printf '%s\n' "$failed" | head -1)
  failed=$(printf '%s\n' "$failed" | sed 1d)

  # ONE jq for the whole table.
  #
  # The obvious shape — a shell loop extracting each field — costs about
  # seven jq processes per project, which dominated the runtime of a warm
  # `cx ls` far more than the network ever did. Formatting in jq keeps a
  # cached listing at process-startup cost regardless of project count.
  local rows=""
  if [ "${total:-0}" -gt 0 ]; then
    rows=$(printf '%s\n' "$raw" |
      jq -rs "${jargs[@]+"${jargs[@]}"}" "$CX_FILTER_JQ$_LS_SELECT$_LS_ROWS")
  fi

  if [ -z "$rows" ] && [ -z "$failed" ]; then
    if [ "$filtering" = true ] && [ "${total:-0}" -gt 0 ]; then
      note "Nothing matches."
      _ls_not_a_host "$host_pos" "$pos1"
    else
      note "No projects yet."
      hint "create one with: cx new <host>:<name>"
    fi
    return 0
  fi

  if [ -n "$rows" ]; then
    {
      if [ "$group" = host ]; then
        if [ -n "$want_git" ]; then
          printf 'PROJECT\tBRANCH\t \tSESSIONS\tACTIVE\tLIVE\tREPO\n'
        else
          printf 'PROJECT\tBRANCH\tSESSIONS\tACTIVE\tLIVE\tREPO\n'
        fi
      elif [ -n "$want_git" ]; then
        printf 'HOST\tPROJECT\tBRANCH\t \tSESSIONS\tACTIVE\tLIVE\tREPO\n'
      else
        printf 'HOST\tPROJECT\tBRANCH\tSESSIONS\tACTIVE\tLIVE\tREPO\n'
      fi
      printf '%s\n' "$rows"
    } | cx_table
  elif [ "$filtering" = true ] && [ "${total:-0}" -gt 0 ]; then
    note "Nothing matches on the servers that answered."
    _ls_not_a_host "$host_pos" "$pos1"
  fi

  # A partial view must announce itself. Silently omitting a server's projects
  # would make `cx ls` look authoritative while being wrong. Only servers in
  # scope are here: --host and a positional host narrow the fan-out itself,
  # while a pattern does not — a server that did not answer might hold a match.
  if [ -n "$failed" ]; then
    say ""
    printf '%s\n' "$failed" | while IFS= read -r h; do
      [ -n "$h" ] || continue
      warn "$h unreachable — its projects are not shown"
    done
    hint "diagnose with: cx host test <host>"
  fi
}

# Filtering and sorting, shared by the JSON and the table: `projects` turns
# the slurped fan-out into the list to show. With no filter and no sort every
# step is the identity, so plain `cx ls` is unchanged byte for byte —
# test/unit/ls.test.sh holds it to that.
# shellcheck disable=SC2016  # jq program text: $vars are jq's, not the shell's
_LS_SELECT='
  def touched: (.last_active // 0) != 0;
  def state_ok:
    (if $live  then (.tmux_live == true or (.tmux_count // 0) > 0) else true end)
    and (if $dirty then .dirty == true else true end)
    and (if $idle >= 0
         then (touched | not) or (($now - .last_active) >= $idle) else true end)
    and (if $active >= 0
         then touched and (($now - .last_active) < $active) else true end);

  # A project stays if it passes everything itself, or if any of its
  # worktrees does — then only as the heading for those worktrees. When the
  # project matched the pattern, its worktrees inherit that match and face
  # only the state filters.
  def filt:
    . as $p
    | ([$p.host, $p.name, $p.branch, $p.repo, "\($p.host):\($p.name)"]
       | cx_any($pat)) as $pm
    | (if $nowt then []
       else [ $p.worktrees[]?
              | select(($pm or ([.name, .branch, "\($p.name)/\(.name)",
                                 "\($p.host):\($p.name)/\(.name)"] | cx_any($pat)))
                       and state_ok) ]
       end) as $wts
    | if ($pm and ($p | state_ok)) or ($wts | length > 0) then
        if $nowt then del(.worktrees)
        elif has("worktrees") then .worktrees = $wts
        else . end
      else empty end;

  # A project counts its worktrees: one whose worktree was used a minute ago
  # is recent, whatever the date on the main checkout.
  def recent: [.last_active // 0, (.worktrees[]?.last_active // 0)] | max;
  def total:  [.sessions // 0, (.worktrees[]?.sessions // 0)] | add;
  def order(f):
    sort_by(f) | map(if has("worktrees") then .worktrees |= sort_by(f) else . end);
  def sorted:
    if   $sort == "name"     then order(.name | ascii_downcase)
    elif $sort == "active"   then order(0 - recent)
    elif $sort == "sessions" then order(0 - total)
    elif $sort == "host"     then sort_by(.host, (.name | ascii_downcase))
    else . end;

  def projects:
    [ .[] | select(.ok) as $h | .projects[]? | . + {host: $h.host} | filt ]
    | sorted;
'

# The table rows, one line each. Appended to _LS_SELECT, so it ends in the
# expression the whole program evaluates.
# shellcheck disable=SC2016  # jq program text: $vars are jq's, not the shell's
_LS_ROWS='
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

  # Grouped, the HOST column becomes a heading and every row under it moves in
  # by two, so the nesting still reads with colour off.
  def lead: if $group == "host" then [] else [ . ] end;
  def ind:  if $group == "host" then "  " else "" end;

  def rows:
    . as $p

    # The project itself.
    | ( ($p.host | lead)
        + [ ind + $p.name, ($p.branch // "—") ]
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
        # "merged": nothing on its branch that is not already in the
        # branch of the project itself, so removing it loses no commits.
        # From agent 0.4.0; an older listing has no such field.
        | ("" | lead)
          + [ (ind + "  " + $p.name + "/" + .name),
              ((.branch // "—") + (if .merged == true then " (merged)" else "" end)) ]
          + (if $git then [ (.dirty | dirt) ] else [] end)
          + [ (if .sessions == null then "?" else (.sessions | tostring) end),
              (.last_active | ago),
              (. | live),
              "" ]
        | @tsv );

  if $group == "host" then
    # Servers in fan-out order (alphabetical, or as --host listed them), not
    # re-sorted: --sort decides the order within each, not between them.
    [ .[] | .host ] as $order
    | projects as $all
    | $order[] as $h
    | [ $all[] | select(.host == $h) ] as $mine
    | if ($mine | length) == 0 then empty
      else ($bold + $h + $reset), ($mine[] | rows)
      end
  else
    projects[] | rows
  end
'
