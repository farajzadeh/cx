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

session=""
mode=interactive
tag=plain
prompt=""
danger=no
perm=""
model=""
effort=""
dispname=""

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
    -*) ;; # any other flag: ignored
    *) prompt="${prompt:+$prompt }$1" ;;
  esac
  shift
done

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
