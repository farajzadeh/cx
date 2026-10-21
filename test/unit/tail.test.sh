#!/usr/bin/env bash
# Unit tests for cx tail: a conversation read from where the caller left off.
#
# The agent half is pinned on the cursor, because that is what cx web hands a
# browser and gets back: an offset that stops at the last complete line (so a
# half-written one is read whole next time), and `reset` whenever the offset
# cannot be trusted. The client half is pinned on the argv it sends.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-tail.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

# ===========================================================================
# The agent
# ===========================================================================
[ "$HAVE_JQ" = 1 ] && (
  export CX_DATA_DIR="$TMP/data" CX_CLAUDE_DIR="$TMP/claude"
  export CX_REGISTRY="$TMP/data/projects.json" CX_SESSIONS="$TMP/data/sessions.json"
  export CX_GOALS="$TMP/data/goals.json" CX_STATE_DIR="$TMP/data/state"
  export CX_AGENT_NO_MAIN=1
  mkdir -p "$CX_DATA_DIR" "$TMP/api"

  # shellcheck source=../../server/cx-agent
  . "$ROOT/server/cx-agent"
  set +eu

  cat >"$CX_REGISTRY" <<EOF
{"version":1,"root":"$TMP","projects":[{"name":"api","path":"$TMP/api"}]}
EOF
  U=11111111-2222-3333-4444-555555555555
  printf '{"sessions":{"api@x":{"uuid":"%s"}}}\n' "$U" >"$CX_SESSIONS"
  dir="$CX_CLAUDE_DIR/projects/$(printf '%s' "$TMP/api" | tr -c 'A-Za-z0-9-' '-')"
  mkdir -p "$dir"
  T="$dir/$U.jsonl"

  long=$(printf '%03000d' 0)
  {
    printf '%s\n' '{"type":"permission-mode","permissionMode":"default"}'
    printf '%s\n' '{"type":"user","uuid":"u1","timestamp":"2026-10-21T10:00:00Z","message":{"role":"user","content":"fix the build"}}'
    printf '%s\n' '{"type":"user","isMeta":true,"message":{"content":"<local-command-caveat>"}}'
    printf '%s\n' '{"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"Looking."},{"type":"tool_use","name":"Bash","input":{"command":"make   -j4\n  test"}}],"stop_reason":"tool_use"}}'
    printf '%s\n' '{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"a subagent"}]}}'
    printf '{"type":"user","uuid":"u2","message":{"content":[{"type":"tool_result","is_error":true,"content":"%s"}]}}\n' "$long"
    printf '%s' '{"type":"assistant","uuid":"a2","message":{"content":[{"type":"text","text":"Do'
  } >"$T"
  full=$(wc -c <"$T" | tr -d ' ')
  part=$(tail -n 1 "$T" | wc -c | tr -d ' ')

  tailj() { (cmd_tail api --session x "$@") 2>"$TMP/err"; }

  describe "agent: tail, a first read"
  out=$(tailj)
  it "reads the main thread's messages, and nothing else"
  assert_eq "$(printf '%s' "$out" | jq -c '[.messages[].id]')" '["u1","a1","u2"]'
  it "says which conversation it read, and that this is not a continuation"
  assert_eq "$(printf '%s' "$out" | jq -r '.uuid, .reset' | tr '\n' ' ')" "$U true "
  it "stops its offset before the half-written last line"
  assert_eq "$(printf '%s' "$out" | jq -r .offset)" "$((full - part))"
  assert_eq "$(printf '%s' "$out" | jq -r .size)" "$full"
  it "shows a tool call as its name and one line of its input"
  assert_eq "$(printf '%s' "$out" | jq -c '.messages[1].tools')" '[{"name":"Bash","summary":"make -j4 test"}]'
  it "cuts a tool result to 2 KB, and keeps whether it failed"
  assert_eq "$(printf '%s' "$out" | jq -r '.messages[2].results[0] | "\(.error) \(.text | length)"')" "true 2001"
  it "--max keeps the newest"
  assert_eq "$(tailj --max 1 | jq -c '[.messages[].id]')" '["u2"]'

  describe "agent: tail, continuing"
  off=$(printf '%s' "$out" | jq -r .offset)
  it "nothing new reads as nothing, at the same offset"
  out=$(tailj --from "$off" --uuid "$U")
  assert_eq "$(printf '%s' "$out" | jq -c '[.reset, .offset, (.messages | length)]')" "[false,$off,0]"
  it "the line that was half-written is read whole once it is finished"
  printf '%s\n' 'ne."}],"stop_reason":"end_turn"}}' >>"$T"
  out=$(tailj --from "$off" --uuid "$U")
  assert_eq "$(printf '%s' "$out" | jq -c '[.reset, (.messages | map(.id)), (.messages[0].text)]')" '[false,["a2"],"Done."]'
  assert_eq "$(printf '%s' "$out" | jq -r .offset)" "$(wc -c <"$T" | tr -d ' ')"

  describe "agent: tail, when the cursor cannot be trusted"
  it "another conversation's offset starts again"
  assert_eq "$(tailj --from "$off" --uuid aaaaaaaa-2222-3333-4444-555555555555 | jq -r .reset)" true
  it "an offset past the end starts again"
  assert_eq "$(tailj --from 99999999 --uuid "$U" | jq -r .reset)" true
  it "so does too much written since"
  assert_eq "$(CX_TAIL_MAX_BYTES=10 tailj --from 0 --uuid "$U" | jq -r .reset)" true

  describe "agent: tail, with nothing to read"
  it "a session with no pin has no uuid and no messages, and is not an error"
  out=$(cmd_tail api --session nobody 2>/dev/null)
  assert_eq "$(printf '%s' "$out" | jq -c '[.uuid, .offset, .messages]')" '[null,0,[]]'

  describe "agent: tail, its arguments"
  it "refuses an offset that is not a number"
  (cmd_tail api --from 1x --uuid "$U") >/dev/null 2>&1
  assert_eq "$?" 3
  it "refuses --max 0"
  (cmd_tail api --max 0) >/dev/null 2>&1
  assert_eq "$?" 3
  it "refuses a label that is not one"
  (cmd_tail api --session 'a;b') >/dev/null 2>&1
  assert_eq "$?" 3

  summary
)
[ "$HAVE_JQ" = 1 ] || printf '  (agent half skipped: no jq)\n'

# ===========================================================================
# The client
# ===========================================================================
export CX_HOME="$ROOT"
# shellcheck source=../../lib/compat.sh
. "$ROOT/lib/compat.sh"
# shellcheck source=../../lib/config.sh
. "$ROOT/lib/config.sh"
# shellcheck source=../../lib/ui.sh
. "$ROOT/lib/ui.sh"
# shellcheck source=../../lib/cmd/tail.sh
. "$ROOT/lib/cmd/tail.sh"

# The target is resolved and the agent is asked; both are stood in for, so
# what is pinned is what cx tail sends.
cx_target_resolve() {
  # shellcheck disable=SC2034  # read by cmd_tail
  CX_T_HOST=web1 CX_T_PROJECT=api CX_T_WORKTREE="" CX_T_SESSION=x
}
cx_agent_supports() { return 0; }
cx_agent() {
  printf '%s\n' "$@" >"$TMP/argv"
  printf '%s\n' '{"target":"api@x","uuid":"u","offset":7,"size":7,"reset":true,"messages":[{"role":"user","text":"hi","tools":[],"results":[]},{"role":"assistant","text":"","tools":[{"name":"Bash","summary":"ls"}],"results":[]}]}'
}

describe "client: cx tail"
it "sends the target and nothing else by default"
cmd_tail web1:api@x >/dev/null 2>&1
assert_eq "$(tr '\n' ' ' <"$TMP/argv")" "web1 tail api --session x "
it "sends a cursor as --from and --uuid, and --max"
cmd_tail web1:api@x --from 42 --uuid u --max 5 >/dev/null 2>&1
assert_eq "$(tr '\n' ' ' <"$TMP/argv")" "web1 tail api --session x --from 42 --uuid u --max 5 "
it "refuses --from without --uuid: an offset means nothing in another conversation"
cmd_tail web1:api@x --from 42 >/dev/null 2>&1
assert_eq "$?" 3
it "refuses an offset that is not a number"
cmd_tail web1:api@x --from 4x --uuid u >/dev/null 2>&1
assert_eq "$?" 3
if [ "$HAVE_JQ" = 1 ]; then
  it "prints messages for a person"
  assert_eq "$(cmd_tail web1:api@x 2>/dev/null)" "$(printf 'you: hi\n  ▸ Bash  ls')"
  it "--json adds the host"
  assert_eq "$(CX_JSON=1 cmd_tail web1:api@x 2>/dev/null | jq -r .host)" web1
fi

summary
