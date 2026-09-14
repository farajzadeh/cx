#!/usr/bin/env bash
# Unit tests for goals that drive themselves: `goal on-stop`, and the driver
# pass a member's Stop hook starts.
#
# This is the one place cx starts Claude on its own, so what is pinned here is
# mostly what it refuses to do: start a pass for a paused goal, for a session
# that is not a member, past the hourly cap, while one is already running, or
# without the driver's instructions. Claude itself is a fake that records how
# it was called and, when told to, stays running long enough to hold the lock.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-onstop.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export CX_DATA_DIR="$TMP/data" CX_CLAUDE_DIR="$TMP/claude"
export CX_REGISTRY="$TMP/data/projects.json" CX_SESSIONS="$TMP/data/sessions.json"
export CX_GOALS="$TMP/data/goals.json" CX_STATE_DIR="$TMP/data/state"
export CX_NOTIFY="$TMP/no-notifier"
export CX_AGENT_NO_MAIN=1
mkdir -p "$CX_DATA_DIR" "$TMP/api"

# shellcheck source=../../server/cx-agent
. "$ROOT/server/cx-agent"
set +eu

if ! have jq; then
  describe "on-stop"
  it "needs jq"
  skip "jq unavailable"
  summary
  exit $?
fi

cat >"$TMP/fake-claude" <<'EOF'
#!/bin/sh
{
  printf 'CALL'
  for a in "$@"; do printf '\t%s' "$a"; done
  printf '\n'
} >>"$FAKE_LOG"
[ -n "${FAKE_HOLD:-}" ] && sleep "$FAKE_HOLD"
exit 0
EOF
chmod +x "$TMP/fake-claude"
export FAKE_LOG="$TMP/claude.log"
_find_claude() { printf '%s' "$TMP/fake-claude"; }

printf '{"version":1,"root":"%s","projects":[{"name":"api","path":"%s/api"}]}\n' "$TMP" "$TMP" >"$CX_REGISTRY"
printf '{"version":1,"sessions":{"api@impl":{"uuid":"u-impl"},"api@other":{"uuid":"u-other"}}}\n' >"$CX_SESSIONS"
printf '# driver\nthe rules\n' >"$CX_DATA_DIR/cx-driver.agent.md"

goal_new() {
  printf 'ship it' | (cmd_goal new ship --member api@impl) >/dev/null 2>&1
}
# goal FILTER — FILTER applied to the goal itself, e.g. goal '.on_stop'.
goal() { jq -r ".goals.ship | $1" "$CX_GOALS"; }
# call — everything the fake claude was last called with. A prompt spans
# lines, so this is the whole log rather than the CALL line alone.
call() { cat "$FAKE_LOG" 2>/dev/null; }
stop() { printf '{"session_id":"%s","hook_event_name":"Stop"}' "$1" | cmd_event >"$TMP/stdout" 2>/dev/null; }

# calls N — wait up to three seconds for the fake claude's Nth call.
calls() {
  local i=0
  while [ $i -lt 30 ]; do
    [ "$(grep -c '^CALL' "$FAKE_LOG" 2>/dev/null || echo 0)" -ge "$1" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -c '^CALL' "$FAKE_LOG" 2>/dev/null || echo 0
}
unlocked() {
  local i=0
  while [ $i -lt 50 ] && [ -e "$CX_DATA_DIR/driving/ship.lock" ]; do
    sleep 0.1
    i=$((i + 1))
  done
}

describe "goal on-stop — turning it on and off"

goal_new

it "stays off unless asked"
assert_eq "$(goal .on_stop)" null

it "turns on with a default of six passes an hour"
(cmd_goal on-stop ship) >/dev/null 2>&1
assert_eq "$(goal .on_stop.max_per_hour)" 6

it "takes a cap and a model"
(cmd_goal on-stop ship --max 2 --model haiku) >/dev/null 2>&1
assert_eq "$(goal '.on_stop | "\(.max_per_hour) \(.model)"')" "2 haiku"

it "keeps the change in the goal's history"
assert_eq "$(goal '.revisions[-1].field')" on_stop

it "refuses a cap of zero, which is what --off is for"
(cmd_goal on-stop ship --max 0) >/dev/null 2>&1
assert_eq "$?" 3

it "refuses a model name that is not one"
(cmd_goal on-stop ship --model 'haiku; rm -rf /') >/dev/null 2>&1
assert_eq "$?" 3

describe "a member finishing a turn starts one pass"

rm -f "$FAKE_LOG"
stop u-impl

it "starts Claude"
assert_eq "$(calls 1)" 1

it "in print mode, one pass"
assert_contains "$(call)" "	-p	"

it "names the goal and the member in the prompt"
assert_contains "$(call)" "Member that just finished a turn: api@impl"

it "hands it the driver's instructions"
assert_contains "$(call)" "the rules"

it "lets it run the agent and nothing broader"
# The agent names itself by $0 when that is absolute, and by its installed
# path otherwise — here the test was run by a relative path.
case "$0" in
  /*) AGENT_BIN="$0" ;;
  *) AGENT_BIN="$HOME/.local/bin/cx-agent" ;;
esac
assert_contains "$(call)" "Bash($AGENT_BIN *)"

it "never lets it wait on a permission prompt nobody will answer"
assert_contains "$(call)" "dontAsk"

it "uses the model the goal asked for"
assert_contains "$(call)" "	--model	haiku"

it "records the pass in the goal log"
assert_eq "$(goal '[.log[] | select(.event == "on-stop")] | length')" 1

it "prints nothing back to Claude"
assert_eq "$(cat "$TMP/stdout")" ""

it "releases the lock when the pass ends"
unlocked
assert_fail test -e "$CX_DATA_DIR/driving/ship.lock"

describe "and refuses the rest"

it "starts no second pass while one is still running"
rm -f "$FAKE_LOG"
export FAKE_HOLD=2
stop u-impl
calls 1 >/dev/null
stop u-impl
sleep 0.5
assert_eq "$(calls 2)" 1
unset FAKE_HOLD
unlocked

it "stops at the hourly cap"
# Two passes an hour is this goal's cap, and it has had two.
rm -f "$FAKE_LOG"
stop u-impl
sleep 0.5
assert_eq "$(calls 1)" 0

it "says so in the log, once"
stop u-impl
assert_eq "$(goal '[.log[] | select(.event == "on-stop-capped")] | length')" 1

it "ignores a session that is not a member"
(cmd_goal on-stop ship --max 60) >/dev/null 2>&1
rm -f "$FAKE_LOG"
stop u-other
sleep 0.5
assert_eq "$(calls 1)" 0

it "ignores every event but Stop"
printf '{"session_id":"u-impl","hook_event_name":"PostToolUse"}' | cmd_event >/dev/null 2>&1
sleep 0.5
assert_eq "$(calls 1)" 0

it "starts nothing for a paused goal"
(cmd_goal state ship paused) >/dev/null 2>&1
stop u-impl
sleep 0.5
assert_eq "$(calls 1)" 0
(cmd_goal state ship active) >/dev/null 2>&1

it "starts nothing once turned off"
(cmd_goal on-stop ship --off) >/dev/null 2>&1
stop u-impl
sleep 0.5
assert_eq "$(calls 1)" 0

it "starts nothing without the driver's instructions, and says why"
(cmd_goal on-stop ship --max 60) >/dev/null 2>&1
rm -f "$CX_DATA_DIR/cx-driver.agent.md"
stop u-impl
sleep 0.5
assert_eq "$(calls 1)" 0

it "pointing at cx provision"
assert_contains "$(goal '.log[-1].text')" "cx provision"

summary
