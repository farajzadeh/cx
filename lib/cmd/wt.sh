#!/usr/bin/env bash
# lib/cmd/wt.sh — `cx wt` / `cx worktree` — git worktrees for parallel tasks.
#
# A worktree is a second checkout of the same repository on a different branch,
# sharing one .git directory. That is what makes it the right primitive for
# working on several tasks at once: two Claude sessions in two worktrees edit
# different files on different branches and cannot collide, where two sessions
# in one directory would fight over the same working tree.
#
# cx stores nothing about worktrees. `git worktree list` on the server is the
# only source of truth — see lib/target.sh and the agent's worktree section.

# shellcheck source=../target.sh
. "$CX_HOME/lib/target.sh"

_wt_usage() {
  cat <<EOF
${C_BOLD}cx wt${C_RESET} — git worktrees, for working on several tasks at once

  cx wt add <host>:<project>/<name> [--branch B] [--from REF]
  cx wt ls  [<host>[:<project>]]
  cx wt rm  <host>:<project>/<name> [--force]

A worktree is a separate checkout of the same repository on its own branch.
Each one gets its own directory, so parallel Claude sessions never touch each
other's files:

  cx wt add web1:api/authfix          new branch 'authfix' off HEAD
  cx open   web1:api/authfix          work on it
  cx wt add web1:api/bug-123          a second task, at the same time
  cx open   web1:api/bug-123
  cx ls                               see both, with their branches
  cx wt rm  web1:api/authfix          done — the branch is kept

OPTIONS
  --branch B    branch name, if it should differ from the worktree name.
                An existing branch is checked out rather than recreated.
  --from REF    what to branch from (default: HEAD)
  --force       for rm: discard uncommitted changes in the worktree

Removing a worktree never deletes its branch, so nothing committed is lost.
Use plain git on the server if you want the branch gone too.

Related: cx open <target>@<label> for a second conversation on the SAME files.
EOF
}

# _wt_target TARGET SUB — resolve, and require the worktree component.
# SUB is only used to phrase the correction, e.g. "did you mean: cx wt rm ...".
_wt_target() {
  local target="$1" sub="${2:-add}"

  cx_target_resolve "$target" || return $?

  [ -n "$CX_T_WORKTREE" ] || {
    err "no worktree named in: $target"
    hint "usage: <host>:<project>/<worktree>"
    hint "for example: ${CX_T_HOST:-web1}:$CX_T_PROJECT/authfix"
    return 3
  }
  [ -z "$CX_T_SESSION" ] || {
    err "a session label makes no sense here: @$CX_T_SESSION"
    hint "did you mean: cx wt $sub $CX_T_HOST:$CX_T_PROJECT/$CX_T_WORKTREE"
    return 3
  }

  cx_agent_units_ok "$CX_T_HOST" || return 1
}

_wt_add() {
  local target="" branch="" from=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --branch)
        shift
        branch="${1:-}"
        ;;
      --from)
        shift
        from="${1:-}"
        ;;
      -h | --help)
        _wt_usage
        return 0
        ;;
      -*)
        err "unknown option: $1"
        return 3
        ;;
      *) [ -z "$target" ] && target="$1" ;;
    esac
    shift
  done

  [ -n "$target" ] || {
    err "no target given"
    hint "usage: cx wt add <host>:<project>/<name> [--branch B] [--from REF]"
    return 3
  }

  _wt_target "$target" add || return $?

  # stdout only: the agent logs git's clone/checkout chatter to stderr, and
  # merging the two corrupts the JSON the moment git says anything.
  local out rc=0
  if [ -n "$branch" ] && [ -n "$from" ]; then
    out=$(cx_agent "$CX_T_HOST" worktree add "$CX_T_PROJECT" "$CX_T_WORKTREE" \
      --branch "$branch" --from "$from") || rc=$?
  elif [ -n "$branch" ]; then
    out=$(cx_agent "$CX_T_HOST" worktree add "$CX_T_PROJECT" "$CX_T_WORKTREE" \
      --branch "$branch") || rc=$?
  elif [ -n "$from" ]; then
    out=$(cx_agent "$CX_T_HOST" worktree add "$CX_T_PROJECT" "$CX_T_WORKTREE" \
      --from "$from") || rc=$?
  else
    out=$(cx_agent "$CX_T_HOST" worktree add "$CX_T_PROJECT" "$CX_T_WORKTREE") || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    # The agent already explained itself on stderr; only add the next step.
    case "$rc" in
      2) hint "list what exists with: cx ls $CX_T_HOST" ;;
      4) hint "pick another name, or open the existing one: cx open $(cx_target_str)" ;;
      255) hint "could not reach $CX_T_HOST — check with: cx host test $CX_T_HOST" ;;
    esac
    return "$rc"
  fi

  # A new worktree changes what cx ls reports for this host.
  cx_cache_invalidate "$CX_T_HOST" 2>/dev/null || true

  if [ "${CX_JSON:-0}" = 1 ]; then
    printf '%s' "$out" | jq -c --arg h "$CX_T_HOST" '. + {host:$h}' || printf '%s\n' "$out"
    return 0
  fi

  # `|| true` on every extraction: under `set -e` a failed command
  # substitution in an assignment aborts the function silently.
  local wpath="" wbranch=""
  wpath=$(printf '%s' "$out" | jq -r '.path // empty' 2>/dev/null) || true
  wbranch=$(printf '%s' "$out" | jq -r '.branch // empty' 2>/dev/null) || true

  say "  $(ok_mark) created $(cx_target_str)"
  [ -n "$wbranch" ] && note "    branch $wbranch"
  [ -n "$wpath" ] && note "    $wpath"
  say ""
  hint "start working: cx open $(cx_target_str)"
}

_wt_ls() {
  local filter="" only_host="" only_project=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        _wt_usage
        return 0
        ;;
      -*)
        err "unknown option: $1"
        return 3
        ;;
      *) [ -z "$filter" ] && filter="$1" ;;
    esac
    shift
  done

  # A filter may be a host, or a host:project. Split it by hand rather than
  # resolving: "cx wt ls web1" names a server, not a project.
  if [ -n "$filter" ]; then
    case "$filter" in
      *:*)
        cx_target_split "$filter" || return 3
        only_host="$CX_T_HOST"
        only_project="$CX_T_PROJECT"
        ;;
      *)
        if cx_host_exists "$filter"; then
          only_host="$filter"
        else
          cx_target_resolve "$filter" || return $?
          only_host="$CX_T_HOST"
          only_project="$CX_T_PROJECT"
        fi
        ;;
    esac
  fi

  # Reuse the project listing rather than adding a second round trip: `cx ls`
  # already carries every project's worktrees, and it is cached.
  local raw
  cx_spinner_start "querying servers"
  if [ -n "$only_host" ]; then
    if ! raw=$(cx_projects_get "$only_host" ""); then
      cx_spinner_stop
      err "could not reach $only_host"
      hint "diagnose with: cx host test $only_host"
      return 1
    fi
  else
    raw=$(cx_projects_fanout)
  fi
  cx_spinner_stop

  local rows
  rows=$(printf '%s\n' "$raw" | jq -r --arg p "$only_project" '
    select(.ok) as $h
    | .projects[]?
    | select($p == "" or .name == $p)
    | . as $proj
    | .worktrees[]?
    | [ $h.host,
        ($proj.name + "/" + .name),
        (.branch // "—"),
        (if .sessions == null then "?" else (.sessions | tostring) end),
        (if .tmux_count > 1 then "●" + (.tmux_count | tostring)
         elif .tmux_live    then "●"
         else "" end)
      ] | @tsv' 2>/dev/null)

  if [ "${CX_JSON:-0}" = 1 ]; then
    printf '%s\n' "$raw" | jq -s --arg p "$only_project" '{
      worktrees: [ .[] | select(.ok) as $h | .projects[]?
                   | select($p == "" or .name == $p) | . as $proj
                   | .worktrees[]? | . + {host: $h.host, project: $proj.name} ]
    }'
    return 0
  fi

  if [ -z "$rows" ]; then
    if [ -n "$only_project" ]; then
      note "No worktrees for $only_project."
    else
      note "No worktrees yet."
    fi
    hint "create one with: cx wt add <host>:<project>/<name>"
    return 0
  fi

  {
    printf 'HOST\tWORKTREE\tBRANCH\tSESSIONS\tLIVE\n'
    printf '%s\n' "$rows"
  } | cx_table
}

_wt_rm() {
  local target="" force=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1 ;;
      -h | --help)
        _wt_usage
        return 0
        ;;
      -*)
        err "unknown option: $1"
        return 3
        ;;
      *) [ -z "$target" ] && target="$1" ;;
    esac
    shift
  done

  [ -n "$target" ] || {
    err "no target given"
    hint "usage: cx wt rm <host>:<project>/<name> [--force]"
    return 3
  }

  _wt_target "$target" rm || return $?

  note "This removes the worktree $(cx_target_str) from the server."
  note "  Its branch is kept, so committed work is safe."
  [ "$force" = 1 ] && warn "  --force discards uncommitted changes in it."
  say ""
  cx_confirm "Continue?" || {
    say "cancelled"
    return 0
  }

  local out rc=0
  if [ "$force" = 1 ]; then
    out=$(cx_agent "$CX_T_HOST" worktree rm "$CX_T_PROJECT" "$CX_T_WORKTREE" --force) || rc=$?
  else
    out=$(cx_agent "$CX_T_HOST" worktree rm "$CX_T_PROJECT" "$CX_T_WORKTREE") || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      2) hint "list what exists with: cx wt ls $CX_T_HOST:$CX_T_PROJECT" ;;
      4) hint "keep the changes, or discard them with: cx wt rm $target --force" ;;
    esac
    return "$rc"
  fi

  # Synchronous, so the next cx ls reflects the removal without --refresh.
  cx_cache_invalidate "$CX_T_HOST"

  if [ "${CX_JSON:-0}" = 1 ]; then
    printf '%s' "$out" | jq -c --arg h "$CX_T_HOST" '. + {host:$h}'
    return 0
  fi

  local killed=0
  killed=$(printf '%s' "$out" | jq -r '.sessions_killed // 0' 2>/dev/null) || killed=0

  say "  $(ok_mark) removed $(cx_target_str)"
  [ "${killed:-0}" -gt 0 ] && note "    stopped $killed running session(s)"
  return 0
}

cmd_wt() {
  local sub="${1:-}"
  shift 2>/dev/null || true

  case "$sub" in
    "" | -h | --help | help)
      _wt_usage
      return 0
      ;;
    add | new) _wt_add "$@" ;;
    ls | list) _wt_ls "$@" ;;
    rm | remove | delete) _wt_rm "$@" ;;
    *)
      err "unknown subcommand: cx wt $sub"
      hint "expected one of: add, ls, rm"
      return 3
      ;;
  esac
}

# `cx worktree` is the same command spelled out; worktree.sh is a symlink to
# this file, exactly as resume.sh and shell.sh are to open.sh.
cmd_worktree() { cmd_wt "$@"; }
