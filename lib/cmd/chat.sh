#!/usr/bin/env bash
# lib/cmd/chat.sh — `cx chat` — a conversation with Claude, for a program.
#
# What cx open is to a person, this is to a program: the same pinned
# conversation, but as JSON lines on stdin and stdout instead of a terminal,
# with Claude's approvals and questions arriving as lines to answer. The wire
# is in docs/chat.md.
#
# The client does almost nothing, on purpose. It resolves the target and runs
# the agent's chat verb over ssh, exactly like every other verb (invariant 1),
# with the caller's stdin handed straight through. The one thing it adds is
# the host in the first line's target, which only this side knows.

# shellcheck source=../target.sh
. "$CX_HOME/lib/target.sh"

# _chat_exit CODE MESSAGE — the stream's last line, for a chat that ended
# before the agent could say so itself. A program reading stdout is promised
# an exit line whatever happened, and a usage error is no exception.
_chat_exit() {
  jq -nc --argjson c "$1" --arg m "$2" \
    '{type: "cx", event: "exit", code: $c, reason: "error", message: $m}' 2>/dev/null ||
    printf '{"type":"cx","event":"exit","code":%s,"reason":"error","message":"cx chat failed"}\n' "$1"
}

# _chat_relay TARGET — the agent's lines, onto stdout. The first names the
# session the way the agent sees it (api@review); a program talking to several
# servers needs the host as well, so it gets the full target. The rest are
# copied byte for byte by cat, never parsed: a line of Claude's can be
# megabytes, and the contract is that they arrive unchanged.
_chat_relay() {
  local first="" new=""
  IFS= read -r first || [ -n "$first" ] || return 0
  case "$first" in
    *'"target"'*)
      new=$(printf '%s\n' "$first" |
        jq -c --arg t "$1" 'if .type == "cx" and has("target") then .target = $t else . end' 2>/dev/null) || new=""
      [ -n "$new" ] && first="$new"
      ;;
  esac
  printf '%s\n' "$first"
  cat
}

cmd_chat() {
  case "${1:-}" in
    -h | --help)
      cat <<EOF
${C_BOLD}cx chat${C_RESET} — a conversation with Claude, as JSON lines, for a program

  cx chat <target> [--model M] [--permission-mode MODE]
                   [--allowed-tools "Read,Edit,Bash(npm test:*)"]
                   [--append-system-prompt-file FILE]

What cx open is to a person, cx chat is to a program: the same session — the
conversation cx open would attach to — driven by JSON lines on stdin, with
Claude's replies, its requests for approval and its questions as JSON lines
on stdout. Nothing is drawn and no terminal is needed.

  stdin   {"type":"user","message":{"role":"user","content":"..."}}
          {"type":"cx","op":"permission","id":"...","behavior":"allow"}
          {"type":"cx","op":"permission","id":"...","behavior":"deny","message":"..."}
          {"type":"cx","op":"interrupt"}       stop the turn, keep the chat
          {"type":"cx","op":"close"}           finish the turn, then exit
  stdout  {"type":"cx","event":"ready",...}    always first
          Claude Code's own stream-json lines, unchanged
          {"type":"cx","event":"permission_request","id":"...","tool_name":"Bash",...}
          {"type":"cx","event":"exit","code":0,"reason":"eof",...}  always last

A question (AskUserQuestion) is a permission request for that tool; answer it
with behavior allow and {"answers":{"<question>":"<label>"}} as updatedInput.

It runs until stdin closes or op close arrives, then exits once the turn in
progress has finished. It never runs beside a live cx open on the same
session: one conversation has one writer, so that is refused with exit 4.

${C_BOLD}OPTIONS${C_RESET}
  --permission-mode <mode>   default, acceptEdits, plan (and cx open's others)
  --allowed-tools <list>     tools that run without asking, as Claude Code
                             spells them: "Read,Edit,Bash(npm test:*)"
  --append-system-prompt-file <file>
                             a file here whose text is added to Claude's system
                             prompt; it travels over stdin, not the command line
  --model <model>            opus, sonnet, haiku, or a full model id
  --effort <level>           low, medium, high, xhigh, max
  -- <args...>               passed to Claude Code verbatim

Exit: 0 ended normally, 1 error, 2 no such target, 3 usage, 4 refused (a live
session holds the conversation), 255 the connection failed. The full wire
protocol is in docs/chat.md.
EOF
      return 0
      ;;
  esac

  local target="" allowed="" sp_file="" rc=0
  local passthru=()
  cx_claude_opts_reset

  while [ $# -gt 0 ]; do
    if [ "$1" = "--" ]; then
      shift
      while [ $# -gt 0 ]; do
        passthru=("${passthru[@]+"${passthru[@]}"}" "$1")
        shift
      done
      break
    fi

    # `default` is Claude's own mode, spelled out for a program that always
    # sends one. Nothing to pass, so it never reaches cx_claude_opt.
    if [ "$1" = --permission-mode ] && [ "${2:-}" = default ]; then
      shift 2
      continue
    fi

    rc=0
    cx_claude_opt "$1" "${2:-}" || rc=$?
    if [ "$rc" = 0 ]; then
      shift "$CX_CLAUDE_USED"
      continue
    fi
    if [ "$rc" = 2 ]; then
      _chat_exit 3 "bad value for $1"
      return 3
    fi

    case "$1" in
      --allowed-tools | --allowedTools | --append-system-prompt-file)
        if [ -z "${2:-}" ]; then
          err "$1 needs a value"
          _chat_exit 3 "$1 needs a value"
          return 3
        fi
        case "$1" in
          --append-system-prompt-file) sp_file="$2" ;;
          *) allowed="$2" ;;
        esac
        shift
        ;;
      -*)
        err "unknown option: $1"
        hint "to pass it to Claude Code instead: cx chat <target> -- $1"
        _chat_exit 3 "unknown option: $1"
        return 3
        ;;
      *)
        if [ -n "$target" ]; then
          err "unexpected argument: $1"
          hint "cx chat reads the conversation from stdin, not from arguments"
          _chat_exit 3 "unexpected argument: $1"
          return 3
        fi
        target="$1"
        ;;
    esac
    shift
  done

  # Not a picker: there is a program on stdin, not a person.
  if [ -z "$target" ]; then
    err "no target given"
    hint "usage: cx chat <host>:<project>   (JSON lines on stdin)"
    _chat_exit 3 "no target given"
    return 3
  fi
  if [ -n "$sp_file" ] && { [ ! -f "$sp_file" ] || [ ! -r "$sp_file" ]; }; then
    err "cannot read $sp_file"
    _chat_exit 3 "cannot read the system prompt file"
    return 3
  fi

  rc=0
  cx_target_resolve "$target" || rc=$?
  if [ "$rc" != 0 ]; then
    _chat_exit "$rc" "cannot resolve $target"
    return "$rc"
  fi

  local ver=""
  ver=$(cx_agent "$CX_T_HOST" version 2>/dev/null) || true
  if [ -z "$ver" ]; then
    err "the cx agent is not installed on $CX_T_HOST"
    hint "install it with: cx provision $CX_T_HOST"
    _chat_exit 1 "the cx agent is not installed on $CX_T_HOST"
    return 1
  fi
  if ! cx_agent_supports "$CX_T_HOST" "cx chat" 0.6.0 "$ver"; then
    _chat_exit 1 "the cx agent on $CX_T_HOST is too old for cx chat"
    return 1
  fi

  if [ "$CX_CLAUDE_PERM_MODE" = bypassPermissions ]; then
    warn "chatting with ALL permission checks bypassed: nothing will ask"
  fi

  # A chat writes to the conversation, which cx ls reports (invariant 4).
  cx_cache_invalidate "$CX_T_HOST"

  cx_target_args
  local extra=() sep=()
  if [ -n "$allowed" ]; then extra=(--allowed-tools "$allowed"); fi
  if [ -n "$sp_file" ]; then
    extra=("${extra[@]+"${extra[@]}"}" --system-prompt-stdin)
  fi
  [ ${#passthru[@]} -gt 0 ] && sep=(--)

  local opts remote t
  opts=$(cx_ssh_opts)
  remote="$CX_AGENT_PATH$(cx_remote_quote chat "$CX_T_PROJECT" \
    "${CX_T_ARGS[@]+"${CX_T_ARGS[@]}"}" \
    "${CX_CLAUDE_ARGS[@]+"${CX_CLAUDE_ARGS[@]}"}" \
    "${extra[@]+"${extra[@]}"}" \
    "${sep[@]+"${sep[@]}"}" "${passthru[@]+"${passthru[@]}"}")"
  t=$(cx_target_str)

  # The system prompt is text someone wrote, so it goes the way cx ask's prompt
  # goes — over stdin, ahead of the caller's own lines — and never through a
  # command line on either side of the wire.
  local st=0
  if [ -n "$sp_file" ]; then
    # shellcheck disable=SC2086
    {
      jq -Rsc '{type: "cx", op: "system_prompt", append: .}' <"$sp_file"
      cat
    } | ssh $opts "$CX_T_HOST" "$remote" | _chat_relay "$t"
    st=${PIPESTATUS[1]}
  else
    # shellcheck disable=SC2086
    ssh $opts "$CX_T_HOST" "$remote" | _chat_relay "$t"
    st=${PIPESTATUS[0]}
  fi

  # 255 is ssh's own failure: the agent never ran, or the connection went with
  # the stream half-written. Either way its exit line is not coming.
  if [ "$st" = 255 ]; then
    err "lost the connection to $CX_T_HOST"
    _chat_exit 255 "ssh: the connection to $CX_T_HOST failed or was lost"
  fi
  return "$st"
}
