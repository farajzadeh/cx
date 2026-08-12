#!/usr/bin/env bash
# lib/cmd/rm.sh — `cx rm` — unregister a project, optionally deleting it.
#
# Two very different operations behind one command, so the distinction is made
# loudly: without --purge this only forgets the project, and the files stay
# exactly where they are.

# shellcheck source=../target.sh
. "$CX_HOME/lib/target.sh"

cmd_rm() {
  local target="" purge=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --purge) purge=1 ;;
      -h | --help)
        cat <<EOF
${C_BOLD}cx rm${C_RESET} — remove a project from cx

  cx rm <host>:<name>            unregister; files are left untouched
  cx rm <host>:<name> --purge    unregister AND delete the directory

Without --purge this only removes the registry entry, so the project stops
appearing in cx ls. Nothing on disk changes and you can re-add it later.

--purge deletes the project directory on the server. That is not reversible.
EOF
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
    hint "usage: cx rm <host>:<name> [--purge]"
    return 3
  }

  cx_target_resolve "$target" || return $?

  # cx rm operates on whole projects. Silently widening a worktree target to
  # its project would delete far more than was asked for, so refuse and name
  # the command that does what they meant.
  if [ -n "$CX_T_WORKTREE" ]; then
    err "cx rm removes a whole project, not a worktree"
    hint "remove just the worktree with: cx wt rm $(cx_target_str)"
    hint "or remove the whole project with: cx rm $CX_T_HOST:$CX_T_PROJECT"
    return 3
  fi
  if [ -n "$CX_T_SESSION" ]; then
    err "cx rm removes a project, not a session"
    hint "end the session with: cx stop $(cx_target_str)"
    return 3
  fi

  local path=""
  path=$(cx_agent "$CX_T_HOST" path "$CX_T_PROJECT" 2>/dev/null) || true

  # Worktrees are removed along with the project, and they hold branches whose
  # work may live nowhere else. Counting them costs one call and is worth it
  # before an irreversible prompt.
  local wt_names=""
  wt_names=$(cx_agent "$CX_T_HOST" worktree list "$CX_T_PROJECT" 2>/dev/null |
    jq -r '.worktrees[]?.name' 2>/dev/null | tr '\n' ' ') || true

  if [ "$purge" = 1 ]; then
    warn "This deletes $(cx_target_str) and everything in it."
    [ -n "$path" ] && note "  $CX_T_HOST:$path"
    [ -n "$wt_names" ] && warn "  and its worktrees: $wt_names"
    note "  This cannot be undone."
  else
    note "This removes $(cx_target_str) from cx."
    [ -n "$path" ] && note "  The files stay at $CX_T_HOST:$path"
    note "  Re-add it later with: cx new $(cx_target_str)"
  fi
  say ""
  cx_confirm "Continue?" || {
    say "cancelled"
    return 0
  }

  local out rc=0
  if [ "$purge" = 1 ]; then
    out=$(cx_agent "$CX_T_HOST" rm "$CX_T_PROJECT" --purge) || rc=$?
  else
    out=$(cx_agent "$CX_T_HOST" rm "$CX_T_PROJECT") || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    hint "check the server with: cx host test $CX_T_HOST"
    return "$rc"
  fi

  # Synchronous, so the next `cx ls` reflects the removal without --refresh.
  cx_cache_invalidate "$CX_T_HOST"

  if [ "${CX_JSON:-0}" = 1 ]; then
    printf '%s' "$out" | jq -c --arg h "$CX_T_HOST" '. + {host:$h}'
    return 0
  fi

  if [ "$purge" = 1 ]; then
    say "  $(ok_mark) deleted $(cx_target_str)"
  else
    say "  $(ok_mark) removed $(cx_target_str) from cx (files kept)"
  fi
}
