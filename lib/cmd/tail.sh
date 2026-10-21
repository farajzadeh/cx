#!/usr/bin/env bash
# lib/cmd/tail.sh — `cx tail` — a session's conversation, from where you left off.
#
# What cx web streams, and a CLI command in its own right, because the board
# must not be able to do anything the CLI cannot. One shot like every verb
# (invariant 11): it reads what was appended since OFFSET and returns. The
# caller keeps the offset and decides when to ask again; for cx web that is a
# browser's EventSource, which hands it back as Last-Event-ID.

# shellcheck source=../target.sh
. "$CX_HOME/lib/target.sh"

cmd_tail() {
  local target="" from="" uuid="" max=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        cat <<EOF
${C_BOLD}cx tail${C_RESET} — a session's conversation, read from where you left off

  cx tail <target>                        its last 40 messages
  cx tail <target> --max N                its last N (1-500)
  cx tail <target> --json                 the same, as JSON, with the offset
  cx tail <target> --from OFFSET --uuid U what was written after OFFSET

Main thread only: user and assistant text in full, each tool call as one line,
each tool result cut short. Subagents' turns are left out.

With --json the answer carries ${C_BOLD}offset${C_RESET}, how far it read, and ${C_BOLD}uuid${C_RESET}, the
conversation it read. Pass both back to get only what came after. ${C_BOLD}reset${C_RESET} is
true when that was not possible — the session now holds another conversation,
or too much was written meanwhile — and the messages are a fresh window.

Nothing is followed and nothing waits: ask again to see more. This is what
cx web streams to a browser.

Related: cx peek (what state each session is in), cx open (attach to it)
EOF
        return 0
        ;;
      --from)
        from="${2:-}"
        shift
        ;;
      --uuid)
        uuid="${2:-}"
        shift
        ;;
      --max)
        max="${2:-}"
        shift
        ;;
      -*)
        err "unknown option: $1"
        return 3
        ;;
      *) [ -z "$target" ] && target="$1" ;;
    esac
    shift
  done

  case "$from" in *[!0-9]*)
    err "--from wants a byte offset"
    return 3
    ;;
  esac
  case "$max" in *[!0-9]*)
    err "--max wants a number"
    return 3
    ;;
  esac
  if [ -n "$from" ] && [ -z "$uuid" ]; then
    err "--from needs --uuid: an offset means nothing in another conversation"
    return 3
  fi

  [ -n "$target" ] || {
    err "no target given"
    hint "usage: cx tail <host>:<project>[/<worktree>][@<label>]"
    return 3
  }
  cx_target_resolve "$target" || return $?
  cx_agent_supports "$CX_T_HOST" "cx tail" 0.8.0 || return 1

  local args=()
  [ -n "$from" ] && args=(--from "$from" --uuid "$uuid")
  [ -n "$max" ] && args=("${args[@]+"${args[@]}"}" --max "$max")
  cx_target_args

  local out=""
  out=$(cx_agent "$CX_T_HOST" tail "$CX_T_PROJECT" \
    "${CX_T_ARGS[@]+"${CX_T_ARGS[@]}"}" "${args[@]+"${args[@]}"}") || return $?

  if [ "${CX_JSON:-0}" = 1 ]; then
    printf '%s\n' "$out" | jq -c --arg h "$CX_T_HOST" '{host: $h} + .'
    return 0
  fi

  if [ "$(printf '%s' "$out" | jq -r '.messages | length')" = 0 ]; then
    note "Nothing to show for $(cx_target_str)."
    return 0
  fi
  # One block per message, for a person: who, then the text, then each tool
  # call on a line of its own.
  printf '%s' "$out" | jq -r '
    .messages[]
    | (if .role == "user" then "you" else "claude" end) as $who
    | ( (if .text != "" then "\($who): \(.text)" else empty end),
        (.tools[] | "  ▸ \(.name)  \(.summary)"),
        (.results[] | select(.error) | "  ✗ \(.text | split("\n")[0])") )'
}
