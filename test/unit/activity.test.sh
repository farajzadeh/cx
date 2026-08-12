#!/usr/bin/env bash
# Unit tests for session state: the pure classifier in lib/activity.sh, and
# the transcript reader in server/cx-agent that feeds it.
#
# These two are the whole reason the agent grew a CX_AGENT_NO_MAIN seam. The
# reader's job is to survive a file format nobody promised us — twelve entry
# types, sidechains outnumbering real messages, and a final line that is half
# written because the file is being appended to as we read it. Every one of
# those has a fixture in test/fixtures/transcript/.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

FIX="$ROOT/test/fixtures/transcript"

# shellcheck source=../../lib/compat.sh
. "$ROOT/lib/compat.sh"
# shellcheck source=../../lib/ui.sh
. "$ROOT/lib/ui.sh"
# shellcheck source=../../lib/activity.sh
. "$ROOT/lib/activity.sh"

# Source the agent for its private helpers without running its dispatch. Its
# data paths are pointed at a scratch directory so nothing here can touch a
# real registry or session store.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-activity.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export CX_DATA_DIR="$TMP/data" CX_CLAUDE_DIR="$TMP/claude"
export CX_REGISTRY="$TMP/data/projects.json" CX_SESSIONS="$TMP/data/sessions.json"
export CX_AGENT_NO_MAIN=1
# shellcheck source=../../server/cx-agent
. "$ROOT/server/cx-agent"
# The agent runs under `set -eu`, and sourcing it brings that along. A test
# file deliberately calls things that fail, so turn it back off here.
set +eu

# state ... — cx_activity_state with the grace period pinned, so a change to
# the default can never quietly rewrite what these tests assert.
state() { CX_IDLE_GRACE=120 cx_activity_state "$@"; }

# last_of FIXTURE FIELD — read a fixture the way observe does and report one
# field of the last main-thread message.
last_of() {
  _transcript_messages "$FIX/$1" | tail -n 1 |
    jq -r --arg f "$2" '.[$f] // "" | if type == "array" then join(",") else tostring end' 2>/dev/null
}

count_of() { _transcript_messages "$FIX/$1" | grep -c . || true; }

# ---------------------------------------------------------------------------

describe "cx_activity_state — the ladder"

it "reports dead when there is no tmux session"
assert_eq "$(state false false uuid true assistant end_turn 5)" dead

it "reports dead when the pane is back at a shell, whatever the transcript says"
assert_eq "$(state true true uuid true assistant tool_use 5)" dead

it "reports unknown when no conversation is pinned"
assert_eq "$(state true false '' false '' '' '')" unknown

it "reports fresh when pinned but nothing is written yet"
# Claude writes no transcript until its first exchange, so "just started" and
# "nobody has given it anything to do" are the same fact, and cx does not
# expire one into the other: whether that has gone on too long depends on what
# the caller has already sent, which only the caller knows.
assert_eq "$(state true false uuid false '' '' '')" fresh

it "still reports fresh when the pane has been sitting there a while"
assert_eq "$(state true false uuid true '' '' 9999)" unknown
assert_eq "$(state true false uuid false assistant end_turn 9999)" fresh

it "reports idle when the last turn ended"
assert_eq "$(state true false uuid true assistant end_turn 300)" idle

it "reports idle for a turn that ended seconds ago, not working"
assert_eq "$(state true false uuid true assistant end_turn 2)" idle

it "reports working mid-turn while the transcript is still moving"
assert_eq "$(state true false uuid true assistant tool_use 30)" working

it "reports working at exactly the grace boundary"
assert_eq "$(state true false uuid true assistant tool_use 120)" working

it "reports blocked one second past it"
assert_eq "$(state true false uuid true assistant tool_use 121)" blocked

it "reports blocked when a tool result is the last thing that happened"
assert_eq "$(state true false uuid true user '' 600)" blocked

it "reports unknown when stale and no message was found at all"
assert_eq "$(state true false uuid true '' '' 600)" unknown

it "reports working when fresh even with no message found"
assert_eq "$(state true false uuid true '' '' 10)" working

it "treats an unreadable mtime as no evidence rather than as zero"
assert_eq "$(state true false uuid true assistant tool_use '')" blocked

describe "cx_activity_state — a raised grace period is honoured"

it "calls a 5-minute gap working when the user allows 10"
assert_eq "$(CX_IDLE_GRACE=600 cx_activity_state true false u true assistant tool_use 300)" working

describe "cx_activity_is_steerable"

it "allows a nudge when idle"
assert_ok cx_activity_is_steerable idle

it "allows the first prompt to a session that has not written a transcript yet"
# A brand-new Claude writes nothing until its first exchange, so refusing
# `fresh` would break `open --detach` followed by the task — the driver's
# main flow.
assert_ok cx_activity_is_steerable fresh

it "refuses to type into a working session"
assert_fail cx_activity_is_steerable working

it "refuses to type into a blocked session"
assert_fail cx_activity_is_steerable blocked

it "refuses to type into a dead session"
assert_fail cx_activity_is_steerable dead

# ---------------------------------------------------------------------------
#
# Everything above is pure bash and runs anywhere. Everything below needs jq,
# which cx requires in production but which the bash:3.2 image used by
# `test/run.sh --bash32` does not carry — and that run is asking about bash,
# not about jq. Skip rather than fail, the same way the integration suites
# treat a missing Docker.

if ! cx_have jq; then
  describe "_transcript_messages"
  it "needs jq"
  skip "jq unavailable"
  summary
  exit $?
fi

describe "_transcript_messages — reading a format nobody promised us"

it "finds a finished turn"
assert_eq "$(last_of end_turn.jsonl stop_reason)" end_turn

it "finds a turn still in progress"
assert_eq "$(last_of tool_use.jsonl stop_reason)" tool_use

it "names the tools an in-progress turn is running"
assert_eq "$(last_of tool_use.jsonl tools)" Bash

it "keeps the assistant's text"
assert_contains "$(last_of end_turn.jsonl text)" "retries added"

it "ignores bookkeeping entries after the last message"
assert_eq "$(last_of noise_tail.jsonl stop_reason)" end_turn

it "ignores entry types that did not exist when this was written"
assert_eq "$(last_of unknown_type.jsonl stop_reason)" end_turn

it "skips sidechain turns and reports the main thread"
assert_eq "$(last_of sidechain.jsonl stop_reason)" end_turn

it "returns only main-thread messages from a sidechain-heavy file"
assert_eq "$(count_of sidechain.jsonl)" 2

it "drops a half-written final line instead of failing"
assert_eq "$(last_of truncated.jsonl stop_reason)" end_turn

it "survives a half-written final line without an error exit"
assert_ok _transcript_messages "$FIX/truncated.jsonl"

it "marks a tool result as one"
assert_eq "$(_transcript_messages "$FIX/sidechain.jsonl" | tail -n 1 | jq -r .tool_result)" false

describe "_transcript_messages — nothing to report is not an error"

it "says nothing for an empty transcript"
assert_eq "$(_transcript_messages "$FIX/empty.jsonl")" ""

it "exits 0 on an empty transcript"
assert_ok _transcript_messages "$FIX/empty.jsonl"

it "says nothing for a file that is not JSON at all"
assert_eq "$(_transcript_messages "$FIX/garbage.jsonl")" ""

it "exits 0 on a file that is not JSON at all"
assert_ok _transcript_messages "$FIX/garbage.jsonl"

it "exits 0 when the file does not exist"
assert_ok _transcript_messages "$FIX/no-such-file.jsonl"

describe "an unreadable transcript classifies as unknown, never as an error"

it "yields unknown when the reader found nothing and time has passed"
assert_eq \
  "$(state true false uuid true "$(last_of garbage.jsonl role)" '' 600)" \
  unknown

# ---------------------------------------------------------------------------

describe "_session_dir — the Claude store's path encoding"

it "replaces slashes with dashes"
assert_eq "$(_session_dir /home/u/projects/api)" "$CX_CLAUDE_DIR/projects/-home-u-projects-api"

it "replaces the dot in .worktrees too, which slashes-only got wrong"
assert_eq "$(_session_dir /home/u/projects/.worktrees/api)" \
  "$CX_CLAUDE_DIR/projects/-home-u-projects--worktrees-api"

it "replaces every character outside [A-Za-z0-9-]"
assert_eq "$(_session_dir /home/u/my_app.v2)" "$CX_CLAUDE_DIR/projects/-home-u-my-app-v2"

it "leaves digits and existing dashes alone"
assert_eq "$(_session_dir /home/u/projects/salam2-x)" \
  "$CX_CLAUDE_DIR/projects/-home-u-projects-salam2-x"

describe "_slug_parse — a slug back into its parts"

parse() {
  _slug_parse "$1"
  printf 'project=%s wt=%s label=%s' "$_SP_PROJECT" "$_SP_WT" "$_SP_LABEL"
}

it "parses a bare project"
assert_eq "$(parse api)" "project=api wt= label="

it "parses a worktree"
assert_eq "$(parse api/authfix)" "project=api wt=authfix label="

it "parses a label"
assert_eq "$(parse api@review)" "project=api wt= label=review"

it "parses both"
assert_eq "$(parse api/authfix@tests)" "project=api wt=authfix label=tests"

it "keeps a dot in the project name, which the grammar allows"
assert_eq "$(parse my.app@rev)" "project=my.app wt= label=rev"

it "round-trips every form through _slug"
assert_eq "$(_slug_parse api/authfix@tests && _slug "$_SP_PROJECT" "$_SP_WT" "$_SP_LABEL")" \
  api/authfix@tests

describe "_is_shell_cmd — has Claude exited?"

it "recognises a bare shell"
assert_ok _is_shell_cmd bash

it "recognises a login shell"
assert_ok _is_shell_cmd -zsh

it "treats claude as running"
assert_fail _is_shell_cmd claude

it "treats node as running, which is what older installs report"
assert_fail _is_shell_cmd node

it "treats an unrecognised command as running rather than as dead"
assert_fail _is_shell_cmd some-future-binary

summary
