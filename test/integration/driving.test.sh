#!/usr/bin/env bash
# Integration tests for driving sessions: observe, peek, nudge and goals.
#
# These need a real tmux and a real (stubbed) Claude staying alive in a pane,
# because the thing being tested is precisely the plumbing between them — a
# prompt going into a tmux pane, a transcript coming back out, and cx reading
# the result. None of that is reachable from a unit test.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"
# shellcheck source=lib/nodes.sh
. "$ROOT/test/integration/lib/nodes.sh"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  describe "driving integration"
  it "requires Docker"
  skip "docker unavailable"
  summary
  exit $?
fi

describe "driving integration"
nodes_build || {
  it "builds the test image"
  _t_no "$_T_NAME" "docker build failed"
  summary
  exit 1
}

HOME_DIR=$(nodes_env)
trap 'nodes_cleanup "$HOME_DIR"' EXIT
P1=$(nodes_start web1 "$HOME_DIR") || {
  it "starts a node"
  _t_no "$_T_NAME" "could not start container"
  summary
  exit 1
}
nodes_add_host "$HOME_DIR" cx-test-web1 "$P1"
cx_run "$HOME_DIR" provision cx-test-web1 >/dev/null 2>&1

NODE="${CX_NODE_PREFIX}web1"
on_node() { docker exec "$NODE" su - cxuser -c "$1" 2>&1; }
agent() { on_node "\$HOME/.local/bin/cx-agent $1"; }

cx_run "$HOME_DIR" new cx-test-web1:api >/dev/null 2>&1

# settle SECONDS — give a pane time to act. A counted sleep loop, because
# timeout(1) is banned and there is nothing here worth polling for.
settle() {
  local n="${1:-1}"
  while [ "$n" -gt 0 ]; do
    sleep 1
    n=$((n - 1))
  done
}

# ---------------------------------------------------------------------------

describe "the agent reports what it can do"

it "advertises its capabilities"
assert_contains "$(agent doctor)" '"observe"'

it "is new enough for driving"
assert_eq "$(agent version)" "$CX_AGENT_VERSION_EXPECTED"

describe "open --detach starts a session without attaching"

_out=$(agent "open api --session impl --detach --mode continue")

it "returns instead of attaching"
assert_contains "$_out" '"attached":false'

it "reports that it created the session"
assert_contains "$_out" '"created":true'

it "pins a conversation id"
assert_ne "$(printf '%s' "$_out" | jq -r '.uuid // ""')" ""

it "really created the tmux session"
assert_ok on_node 'tmux has-session -t "=cx-api@impl"'

it "is idempotent — a second detach does not stack a second Claude"
assert_contains "$(agent 'open api --session impl --detach --mode continue')" '"created":false'

describe "observe reports facts about it"

_obs=$(agent "observe api --session impl")

it "finds the session alive"
assert_contains "$_obs" '"alive":true'

it "knows the pane is not sitting at a shell"
assert_contains "$_obs" '"shell":false'

it "reports no transcript before the first exchange"
# Claude writes nothing until it is spoken to; cx must report that rather than
# inventing a state for it.
assert_eq "$(printf '%s' "$_obs" | jq -r '.sessions[0].transcript.present')" false

it "has nothing to say about the last message yet"
assert_eq "$(printf '%s' "$_obs" | jq -r '.sessions[0].last')" null

describe "cx peek classifies it"

it "calls a session with no conversation fresh"
assert_contains "$(cx_run "$HOME_DIR" peek cx-test-web1:api)" "fresh"

it "says the same thing in --json"
assert_eq \
  "$(cx_run "$HOME_DIR" --json peek cx-test-web1:api | jq -r '.sessions[0].state')" \
  fresh

it "marks it steerable"
assert_eq \
  "$(cx_run "$HOME_DIR" --json peek cx-test-web1:api | jq -r '.sessions[0].steerable')" \
  true

describe "nudge puts a prompt into the running session"

_n=$(cx_run "$HOME_DIR" nudge cx-test-web1:api@impl "write the retry patch")
settle 3

it "reports that it sent it"
assert_contains "$_n" "sent to"

it "the text reached the pane"
assert_contains "$(on_node 'tmux capture-pane -pJ -t "=cx-api@impl:"')" "write the retry patch"

it "the session took it as a turn"
assert_contains "$(on_node 'tmux capture-pane -pJ -t "=cx-api@impl:"')" "STUB: got write the retry patch"

it "a transcript now exists"
assert_eq \
  "$(agent 'observe api --session impl' | jq -r '.sessions[0].transcript.present')" \
  true

it "the last main-thread message is the finished assistant turn"
# The stub also writes a sidechain entry and a last-prompt entry after it, so
# this only passes if the reader skips both.
assert_eq \
  "$(agent 'observe api --session impl' | jq -r '.sessions[0].last.stop_reason')" \
  end_turn

it "peek now calls it idle"
assert_eq \
  "$(cx_run "$HOME_DIR" --json peek cx-test-web1:api | jq -r '.sessions[0].state')" \
  idle

it "the tail carries what was said"
assert_contains \
  "$(cx_run "$HOME_DIR" --json peek cx-test-web1:api --tail 4 | jq -r '.sessions[0].tail[].text')" \
  "write the retry patch"

describe "a multi-line prompt survives"
# send-keys cannot do this at all — the first newline submits — which is why
# nudge goes through a tmux paste buffer.

printf 'first line\nsecond line with $(echo not-expanded) and `backticks`' |
  cx_run "$HOME_DIR" nudge cx-test-web1:api@impl >/dev/null 2>&1
settle 3

it "arrives without the shell touching it"
assert_contains \
  "$(on_node 'tmux capture-pane -pJ -t "=cx-api@impl:"')" \
  'not-expanded'

describe "nudge declines rather than making a mess"

it "refuses a session that is not running"
assert_contains \
  "$(cx_run "$HOME_DIR" nudge cx-test-web1:api@nosuch 'hello')" \
  "not running"

it "exits 0 when it declines, because a busy session is not an error"
run_rc cx_run "$HOME_DIR" nudge cx-test-web1:api@nosuch 'hello'
assert_eq "$_T_RC" 0

it "says why, in --json"
assert_eq \
  "$(cx_run "$HOME_DIR" --json nudge cx-test-web1:api@nosuch 'hello' | jq -r '.reason')" \
  dead

describe "ask refuses to open a second writer on a live conversation"

it "declines with a conflict"
run_rc cx_run "$HOME_DIR" ask cx-test-web1:api@impl "what is going on"
assert_eq "$_T_RC" 4

it "points at nudge instead"
assert_contains "$(cx_run "$HOME_DIR" ask cx-test-web1:api@impl 'hi')" "nudge"

it "an unlabelled ask still works, since it shares no conversation"
assert_contains "$(cx_run "$HOME_DIR" ask cx-test-web1:api 'hi')" "STUB_ANSWER"

describe "a session whose Claude exited reads as dead"

on_node 'tmux send-keys -t "=cx-api@impl:" C-d' >/dev/null 2>&1
settle 3

it "peek notices the pane fell back to a shell"
assert_eq \
  "$(cx_run "$HOME_DIR" --json peek cx-test-web1:api | jq -r '.sessions[0].state')" \
  dead

it "and refuses to nudge it"
assert_eq \
  "$(cx_run "$HOME_DIR" --json nudge cx-test-web1:api@impl 'hello' | jq -r '.sent')" \
  false

describe "goals"

it "creates one"
assert_contains \
  "$(cx_run "$HOME_DIR" goal new ship 'the retry patch is merged' --member api@impl)" \
  "ship"

it "stores the definition of done"
assert_eq \
  "$(cx_run "$HOME_DIR" --json goal show ship | jq -r '.dod')" \
  "the retry patch is merged"

it "records the member, qualified with its host"
assert_contains \
  "$(cx_run "$HOME_DIR" --json goal show ship | jq -r '.members[]')" \
  "api@impl"

it "starts active"
assert_eq "$(cx_run "$HOME_DIR" --json goal show ship | jq -r '.state')" active

it "keeps the old text when the definition of done changes"
cx_run "$HOME_DIR" goal dod ship 'the retry patch is merged and released' >/dev/null 2>&1
assert_eq \
  "$(cx_run "$HOME_DIR" --json goal show ship | jq -r '.revisions[0].from')" \
  "the retry patch is merged"

it "pauses"
cx_run "$HOME_DIR" goal pause ship >/dev/null 2>&1
assert_eq "$(cx_run "$HOME_DIR" --json goal show ship | jq -r '.state')" paused

it "pausing kills nothing"
assert_ok on_node 'tmux has-session -t "=cx-api@impl"'

it "resumes"
cx_run "$HOME_DIR" goal resume ship >/dev/null 2>&1
assert_eq "$(cx_run "$HOME_DIR" --json goal show ship | jq -r '.state')" active

it "records what a driver did"
cx_run "$HOME_DIR" goal log ship 'sent the opening prompt' --event nudge --target api@impl >/dev/null 2>&1
assert_eq \
  "$(cx_run "$HOME_DIR" --json goal show ship | jq -r '.log[-1].text')" \
  "sent the opening prompt"

it "accepts a member on a server it cannot see"
cx_run "$HOME_DIR" goal member add ship other-host:api@tests >/dev/null 2>&1
assert_contains \
  "$(cx_run "$HOME_DIR" --json goal show ship | jq -r '.members[]')" \
  "other-host:api@tests"

it "rejects a local member that does not exist"
run_rc cx_run "$HOME_DIR" goal member add ship no-such-thing
assert_eq "$_T_RC" 2

it "lists them"
assert_contains "$(cx_run "$HOME_DIR" goal ls)" "ship"

describe "removing a project takes its members with it"

cx_run "$HOME_DIR" -y rm cx-test-web1:api >/dev/null 2>&1

it "drops the member that no longer exists"
assert_not_contains \
  "$(cx_run "$HOME_DIR" --json goal show ship | jq -r '.members | join(",")')" \
  "api@impl"

it "keeps the goal, and the member on the other host"
assert_contains \
  "$(cx_run "$HOME_DIR" --json goal show ship | jq -r '.members[]')" \
  "other-host:api@tests"

describe "the session store going missing costs a column, not an error"

on_node 'rm -rf $HOME/.claude/projects' >/dev/null 2>&1

it "peek still succeeds"
run_rc cx_run "$HOME_DIR" peek
assert_eq "$_T_RC" 0

it "reports the sessions it can still see"
# The project was removed above, so its registered sessions are gone with it;
# what matters here is that a missing store is not an error.
assert_not_contains "$(cx_run "$HOME_DIR" peek)" "cx:"

summary
