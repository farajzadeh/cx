#!/usr/bin/env bash
# lib/cmd/forget.sh — `cx forget` — drop a finished session from cx's lists.
#
# cx reports every session it has ever pinned that still has a conversation on
# disk, because a finished session is how a driver knows work needs reviving.
# Over months that becomes most of the list. Forgetting is the way out, and it
# is explicit, never automatic: what it drops is the pin between a session name
# and its conversation, so the name's next `cx open` starts a new conversation.
# Nothing is deleted — the conversation stays where Claude Code keeps it, and
# `cx resume` can still find it.

# shellcheck source=../target.sh
. "$CX_HOME/lib/target.sh"

cmd_forget() {
  local target=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        cat <<EOF
${C_BOLD}cx forget${C_RESET} — drop a finished session from cx peek, cx bar and cx tabs

  cx forget <host>:<project>[/<worktree>]@<label>
  cx forget <host>:<project>[/<worktree>]          the unit's default session

A finished session stays in cx's lists for as long as its conversation exists,
because that is how a driver knows there is work to revive. ${C_BOLD}forget${C_RESET} removes
one you are done with.

What is dropped is only cx's record of which conversation that session name
holds. The conversation itself is untouched and ${C_BOLD}cx resume${C_RESET} can still reach it.
The name's next ${C_BOLD}cx open${C_RESET} starts a new conversation — except a project's
default session, which picks up the newest conversation in its directory, so
that may be the same one again. Use a label for a guaranteed clean start.

A running session is refused: stop it first with cx stop.

Related: cx peek --all (see what is finished), cx stop (end a running one)
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
    hint "usage: cx forget <host>:<project>[@<label>]"
    hint "see what has finished with: cx peek --all"
    return 3
  }

  cx_target_resolve "$target" || return $?

  local ver=""
  ver=$(cx_agent "$CX_T_HOST" version 2>/dev/null) || true
  if [ -z "$ver" ]; then
    err "the cx agent is not installed on $CX_T_HOST"
    hint "install it with: cx provision $CX_T_HOST"
    return 1
  fi
  cx_agent_supports "$CX_T_HOST" "forgetting sessions" 0.4.0 "$ver" || return 1

  if [ "${CX_ASSUME_YES:-0}" != 1 ]; then
    note "Forgetting $(cx_target_str) drops it from cx peek, cx bar and cx tabs."
    note "Its conversation stays on disk; cx resume can still reach it."
    cx_confirm "Forget $(cx_target_str)?" || {
      note "Left alone."
      return 0
    }
  fi

  cx_target_args
  local out="" rc=0
  out=$(cx_agent "$CX_T_HOST" forget "$CX_T_PROJECT" \
    "${CX_T_ARGS[@]+"${CX_T_ARGS[@]}"}") || rc=$?

  case "$rc" in
    0) ;;
    2)
      hint "cx has nothing recorded for $(cx_target_str)"
      return 2
      ;;
    4)
      hint "stop it first with: cx stop $(cx_target_str)"
      return 4
      ;;
    *) return "$rc" ;;
  esac

  # The pin was part of what cx ls and the tab state cache were built from.
  cx_cache_invalidate "$CX_T_HOST"

  if [ "${CX_JSON:-0}" = 1 ]; then
    printf '%s\n' "$out" | jq -c --arg h "$CX_T_HOST" '. + {host: $h}'
    return 0
  fi
  say "forgot $(cx_target_str)"
  hint "its conversation is still there: cx resume $(cx_target_str)"
}
