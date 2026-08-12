#!/usr/bin/env bash
# lib/cmd/driver.sh — `cx driver` — print the driver subagent definition.
#
# cx ships the definition rather than installing it, because where a subagent
# belongs is the user's decision: ~/.claude/agents for every project, or
# .claude/agents inside one repo. Printing it to stdout leaves that choice
# where it belongs, and makes the file trivially reviewable before it is used
# — which matters for a thing whose whole job is acting unattended.

cmd_driver() {
  case "${1:-}" in
    -h | --help)
      cat <<EOF
${C_BOLD}cx driver${C_RESET} — print the cx-driver subagent definition

  cx driver > ~/.claude/agents/cx-driver.md        for every project
  cx driver > .claude/agents/cx-driver.md          for this one

cx-driver is a Claude Code subagent that drives your cx sessions towards their
goals: it reads each goal's definition of done, looks at what every session is
actually doing, and sends the next prompt to whichever one is ready. Install
it, then ask Claude Code to drive your cx goals.

All of the judgement lives in that agent. cx reports facts and moves text; it
never decides that a definition of done has been met. Read the file before you
install it — it is meant to be edited to suit how you work.

Related: cx goal (set a definition of done), cx peek (what is each one doing)
EOF
      return 0
      ;;
  esac

  local f="$CX_HOME/docs/cx-driver.agent.md"
  [ -r "$f" ] || {
    err "the driver definition is missing from this install"
    hint "expected it at: $f"
    return 2
  }
  cat "$f"
}
