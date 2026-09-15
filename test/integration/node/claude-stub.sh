#!/bin/sh
# Stub Claude Code for cx integration tests.
#
# It exists to make the *invocation* observable: tests assert on which flags
# the agent chose, because that is where the interesting logic lives. Real
# Claude Code is never involved, so the suite needs no credentials and no
# network access to Anthropic.
#
# Recognised:
#   --version              a plausible version string
#   -p | --print PROMPT    one-shot mode; echoes STUB_ANSWER
#   --session-id UUID      start a NEW conversation with that id
#   --resume UUID          resume that specific conversation
#   --resume               (no id) the interactive picker
#   --continue             the most recent conversation here
#   --dangerously-skip-permissions   recorded, so tests can assert it was
#                          passed to exactly the sessions that asked for it
#
# The distinction between `--resume UUID` and a bare `--resume` is the whole
# point: cx pins an id per named session, and getting that wrong is what makes
# two parallel sessions collide.
#
# It also writes a TRANSCRIPT, in the shape cx's observe verb reads: one JSON
# object per line under ~/.claude/projects/<encoded cwd>/<uuid>.jsonl, with
# .type, .isSidechain and .message.stop_reason. Without that there is nothing
# for observe to look at and none of the driving commands can be tested.
#
# Interactively it STAYS ALIVE reading stdin, one line per turn, so a nudge
# arriving over tmux send-keys lands somewhere and produces a reply. That is
# also what keeps the pane's command from falling back to a shell, which cx
# reads as "Claude exited".
#
#   CX_STUB_BUSY=1   write a turn that never finishes (stop_reason tool_use)
#                    so the busy/blocked paths can be exercised.
#
# With --settings it also plays the part of Claude Code's hooks: it runs the
# command configured for each event, with the JSON Claude would send on stdin
# — SessionStart on start, UserPromptSubmit and Stop around every turn, and a
# PermissionRequest instead of the Stop when CX_STUB_BUSY=1, which is the event
# real Claude Code fires for a permission prompt. And it keeps
# ~/.claude/sessions/<pid>.json the way real Claude does — busy while a turn
# runs, `waiting` on a permission prompt, idle between turns — so cx's status
# reader has a live file whose pid and start time really are this process's.
# A statusLine in --settings is run the way real Claude runs one, at startup
# and after every turn, with context, cost and usage-limit numbers.

# Run under a distinctly-named copy of sh, so that the pane's foreground
# process is not called "sh".
#
# cx reads a pane whose current command is a shell as "Claude exited", which is
# right in production — Claude Code is a binary of its own name, and a wrapper
# script around it execs, so the pane never sits at a shell while it is
# running. A stub written in sh is the unrealistic case, and without this every
# session it runs in would be reported dead.
if [ "${CX_STUB_TUI:-0}" != 1 ] && [ -x "${HOME:-}/.local/bin/claude-tui" ]; then
  CX_STUB_TUI=1
  export CX_STUB_TUI
  exec "$HOME/.local/bin/claude-tui" "$0" "$@"
fi

session=""
mode=interactive
tag=plain
prompt=""
danger=no
perm=""
model=""
effort=""
dispname=""
settings=""

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      echo "9.9.9 (Claude Code stub)"
      exit 0
      ;;
    # The agent greps --help before passing a newer flag, so that an old
    # Claude Code produces a sentence rather than a pane that exits before you
    # can read the error. This list is what the stub claims to accept; drop a
    # line from it to test the refusal path.
    --help)
      cat <<'HELP'
Usage: claude [options] [command] [prompt]

Options:
  -c, --continue                        Continue the most recent conversation
  -r, --resume [value]                  Resume a conversation by session ID
  --session-id <uuid>                   Use a specific session ID
  --permission-mode <mode>              Permission mode for the session
  --dangerously-skip-permissions        Bypass all permission checks.
  --model <model>                       Model for the current session
  --effort <level>                      Effort level for the current session
  -n, --name <name>                     Set a display name for this session
  --settings <file-or-json>             Additional settings
  --add-dir <directories...>            Additional directories
  --output-format <format>              Output format
  --json-schema <schema>                JSON Schema for structured output
  --max-budget-usd <amount>             Maximum dollar amount
  -p, --print                           Print response and exit
HELP
      exit 0
      ;;
    -p | --print) mode=print ;;
    --session-id)
      shift
      session="${1:-}"
      tag=new
      ;;
    --resume)
      # --resume takes an OPTIONAL value. Treat the next argument as the id
      # only when there is one and it is not itself a flag — exactly the
      # ambiguity the agent orders its arguments to avoid.
      if [ -n "${2:-}" ] && [ "${2#-}" = "${2:-}" ]; then
        shift
        session="$1"
        tag=resume
      else
        tag=picker
      fi
      ;;
    --continue) tag='continue' ;;
    --dangerously-skip-permissions) danger=yes ;;
    --permission-mode)
      shift
      perm="${1:-}"
      [ "$perm" = bypassPermissions ] && danger=yes
      ;;
    --model)
      shift
      model="${1:-}"
      ;;
    --effort)
      shift
      effort="${1:-}"
      ;;
    -n | --name)
      shift
      dispname="${1:-}"
      ;;
    --settings)
      shift
      settings="${1:-}"
      ;;
    -*) ;; # any other flag: ignored
    *) prompt="${prompt:+$prompt }$1" ;;
  esac
  shift
done

# The encoded project directory: every character outside [A-Za-z0-9-] becomes a
# dash. Not just the slashes — cx got that wrong once and lost every worktree's
# history, so the stub reproduces the real rule.
_enc_dir() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9-' '-'
}

_store_dir() {
  printf '%s/.claude/projects/%s' "$HOME" "$(_enc_dir "$(pwd)")"
}

# _append TYPE ROLE STOP TEXT — one transcript line.
_append() {
  [ -n "$session" ] || return 0
  _dir=$(_store_dir)
  mkdir -p "$_dir" 2>/dev/null || return 0
  # Bookkeeping entries and sidechain turns are interleaved with the real
  # messages in a genuine transcript, and a reader that ignores that finds the
  # wrong "last message". Emit some, so the tests exercise the real shape.
  {
    printf '{"type":"%s","isSidechain":false,"sessionId":"%s","timestamp":"%s",' \
      "$1" "$session" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '"message":{"role":"%s","stop_reason":%s,"content":[{"type":"text","text":"%s"}]}}\n' \
      "$2" "$3" "$4"
    printf '{"type":"assistant","isSidechain":true,"sessionId":"%s","message":{"role":"assistant","stop_reason":"tool_use","content":[]}}\n' \
      "$session"
    printf '{"type":"last-prompt","prompt":"%s"}\n' "$4"
  } >>"$_dir/$session.jsonl" 2>/dev/null || true
}

# _hook EVENT [JSON-FIELDS] — run the command --settings configured for EVENT.
_hook() {
  [ -n "$settings" ] && [ -n "$session" ] && command -v jq >/dev/null 2>&1 || return 0
  _cmd=$(printf '%s' "$settings" | jq -r --arg e "$1" '.hooks[$e][0].hooks[0].command // empty' 2>/dev/null)
  [ -n "$_cmd" ] || return 0
  printf '{"session_id":"%s","hook_event_name":"%s","cwd":"%s"%s}' \
    "$session" "$1" "$(pwd)" "${2:-}" | sh -c "$_cmd" >>"$HOME/.cx-stub-hook-stdout" 2>/dev/null || true
}

# _statusline — run the statusLine command --settings configured, with the JSON
# real Claude hands one: at startup and after every turn. The numbers move with
# the turn count so a test can see a later call replace an earlier one. What it
# prints is kept, because that is what Claude would show under its prompt box.
_statusline() {
  [ -n "$settings" ] && [ -n "$session" ] && command -v jq >/dev/null 2>&1 || return 0
  _sl=$(printf '%s' "$settings" | jq -r '.statusLine.command // empty' 2>/dev/null)
  [ -n "$_sl" ] || return 0
  _turns=${_turns:-0}
  printf '{"session_id":"%s","transcript_path":"%s/%s.jsonl","cwd":"%s","workspace":{"current_dir":"%s","project_dir":"%s"},"model":{"id":"stub-model","display_name":"Stub 1 (test)"},"cost":{"total_cost_usd":0.25,"total_lines_added":%s,"total_lines_removed":0},"context_window":{"context_window_size":200000,"used_percentage":%s,"current_usage":{"input_tokens":10,"cache_creation_input_tokens":%s,"cache_read_input_tokens":0}},"rate_limits":{"five_hour":{"used_percentage":9,"resets_at":1789509000},"seven_day":{"used_percentage":56,"resets_at":1789603200}}}' \
    "$session" "$(_store_dir)" "$session" "$(pwd)" "$(pwd)" "$(pwd)" \
    "$_turns" "$_turns" "$((_turns * 2000))" |
    sh -c "$_sl" >>"$HOME/.cx-stub-statusline-stdout" 2>/dev/null || true
}

# _status busy|idle — the per-process status file real Claude keeps.
_status() {
  [ -n "$session" ] || return 0
  mkdir -p "$HOME/.claude/sessions" 2>/dev/null || return 0
  # Worked out once. This runs on every line of input, and three processes a
  # line made the stub slow enough to fall behind a long pasted prompt.
  if [ -z "${_start+x}" ]; then
    _start=$(sed 's/.*) //' "/proc/$$/stat" 2>/dev/null | awk '{print $20}')
    _tmux=""
    [ -n "${TMUX:-}" ] && _tmux=$(tmux display-message -p '#{session_name}:@0.%0' 2>/dev/null)
  fi
  printf '{"pid":%s,"sessionId":"%s","procStart":"%s","kind":"interactive","tmux":"%s","name":"%s","status":"%s","statusUpdatedAt":%s000}\n' \
    "$$" "$session" "$_start" "$_tmux" "$dispname" "$1" "$(date +%s)" \
    >"$HOME/.claude/sessions/$$.json" 2>/dev/null || true
}

# Record every invocation so a test can inspect the full argv history.
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(pwd)" "$mode" "$tag" "$session" "$danger" "$perm" "$model" "$effort" \
  >>"${CX_STUB_LOG:-$HOME/.cx-claude-stub.log}" 2>/dev/null || true

# The marker is printed rather than only logged, because a tmux pane is all a
# test can see for an interactive session.
[ "$danger" = yes ] && echo "STUB_NO_PERMISSIONS"
[ -n "$perm" ] && echo "STUB_PERM_MODE: $perm"
[ -n "$model" ] && echo "STUB_MODEL: $model"
[ -n "$effort" ] && echo "STUB_EFFORT: $effort"
[ -n "$dispname" ] && echo "STUB_NAME: $dispname"

if [ "$mode" = print ]; then
  [ -n "$session" ] && echo "STUB_SESSION: $session"
  echo "STUB_ANSWER: $prompt"
  exit 0
fi

case "$tag" in
  new) echo "STUB: new session $session in $(pwd)" ;;
  resume) echo "STUB: resuming session $session in $(pwd)" ;;
  picker) echo "STUB: resume picker in $(pwd)" ;;
  continue) echo "STUB: continuing session in $(pwd)" ;;
  *) echo "STUB: interactive claude in $(pwd)" ;;
esac

# Real Claude writes nothing until its first exchange, and cx reports that as
# `fresh` — so the stub must not write anything here either.
#
# Then stay alive, one turn per line of stdin. Exiting instead would drop the
# pane back to a shell, which is exactly how cx detects a dead session.
# CX_STUB_TRUST=1 plays the first run in a directory Claude has never trusted:
# a question with "No, exit" selected, and nothing else — no hook, no status
# file — until it is answered. Real Claude exits on a bare Enter there, and so
# does this, which is the whole point: a nudge that types into it ends the
# session. Answering "trust" carries on as normal.
if [ "${CX_STUB_TRUST:-0}" = 1 ]; then
  echo "Quick safety check: Is this a project you created or one you trust?"
  echo "❯ No, exit"
  echo "  Yes, I trust this folder"
  IFS= read -r _answer || exit 1
  if [ "$_answer" != trust ]; then
    echo "STUB: not trusted, exiting"
    exit 1
  fi
fi

_src=startup
[ "$tag" = resume ] && _src=resume
_hook SessionStart ",\"source\":\"$_src\""
_status idle
_statusline

while IFS= read -r line; do
  [ -n "$line" ] || continue
  echo "STUB: got $line"
  _status busy
  _hook UserPromptSubmit
  _append user user null "$line"
  _turns=$((${_turns:-0} + 1))
  if [ "${CX_STUB_BUSY:-0}" = 1 ]; then
    _append assistant assistant '"tool_use"' "working on it"
    _hook PermissionRequest ',"tool_name":"Bash"'
    _status waiting
  else
    _append assistant assistant '"end_turn"' "did: $line"
    _hook Stop
    _status idle
  fi
  _statusline
done
_hook SessionEnd
rm -f "$HOME/.claude/sessions/$$.json" 2>/dev/null || true
