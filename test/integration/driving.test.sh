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

describe "cx open -d — the client half"
#
# Everything above drives the AGENT directly. This drives the client, which is
# the half that assembles the argument vector: the permission flags, the `--`
# passthrough and the detach branch all meet here, and a mistake in that
# assembly is invisible from the agent side. It was untested until a docs
# audit went looking.

_c=$(cx_run "$HOME_DIR" open -d cx-test-web1:api@viaclient 2>&1)

it "starts a session without attaching"
assert_contains "$_c" "started"

it "really created it"
assert_ok on_node 'tmux has-session -t "=cx-api@viaclient"'

it "is idempotent through the client too"
assert_contains "$(cx_run "$HOME_DIR" open -d cx-test-web1:api@viaclient 2>&1)" "already running"

# cx_run merges stderr, and open legitimately warns there — the stub server has
# no Claude credentials, so every open says so. Take the JSON line only, which
# is also the contract: machine-readable on stdout, human-readable on stderr.
_j=$(cx_run "$HOME_DIR" --json open -d cx-test-web1:api@viaclient | grep -E '^\{')

it "reports the session in --json"
assert_eq "$(printf '%s' "$_j" | jq -r '.target')" "api@viaclient"

it "and names the host it went to"
assert_eq "$(printf '%s' "$_j" | jq -r '.host')" "cx-test-web1"

it "keeps the warning off stdout, so the JSON stays parseable"
assert_ok sh -c "printf '%s' '$_j' | jq -e . >/dev/null"

describe "cx open -d carries the permission flags through"
# The line the merge of two branches turned on. Without it a detached session
# launches WITH permission checks, blocks on its first write, and looks like a
# Claude problem rather than a lost argument.

_p=$(cx_run "$HOME_DIR" open -d --dangerously-skip-permissions cx-test-web1:api@perm 2>&1)

it "warns before it starts"
assert_contains "$_p" "ALL permission checks bypassed"

it "says the detached case out loud, since nobody is watching"
assert_contains "$_p" "no one will see it ask"

it "the flag reached Claude"
assert_contains "$(on_node 'tmux capture-pane -pJ -S -200 -t "=cx-api@perm:"')" 'STUB_NO_PERMISSIONS'

it "and the mode was recorded for cx status to show"
assert_eq \
  "$(on_node 'jq -r ".sessions[\"api@perm\"].perm_mode" ~/.local/share/cx/sessions.json')" \
  bypassPermissions

it "--permission-mode arrives the same way"
cx_run "$HOME_DIR" open -d --permission-mode acceptEdits cx-test-web1:api@accept >/dev/null 2>&1
assert_eq \
  "$(on_node 'jq -r ".sessions[\"api@accept\"].perm_mode" ~/.local/share/cx/sessions.json')" \
  acceptEdits

it "rejects a permission mode that does not exist, before touching the server"
run_rc cx_run "$HOME_DIR" open -d --permission-mode nonsense cx-test-web1:api@bogus
assert_eq "$_T_RC" 3

it "and creates no session when it rejects one"
assert_fail on_node 'tmux has-session -t "=cx-api@bogus"'

describe "cx shell refuses Claude options rather than ignoring them"

it "refuses --dangerously-skip-permissions"
assert_contains \
  "$(cx_run "$HOME_DIR" shell cx-test-web1:api --dangerously-skip-permissions 2>&1)" \
  "starts no Claude"

it "refuses --permission-mode too"
assert_contains \
  "$(cx_run "$HOME_DIR" shell cx-test-web1:api --permission-mode plan 2>&1)" \
  "starts no Claude"

it "exits 3, since it is a usage error"
run_rc cx_run "$HOME_DIR" shell cx-test-web1:api --permission-mode plan
assert_eq "$_T_RC" 3

# Leave the fixture as this block found it. Later tests count sessions, and a
# stray one from here would fail them somewhere else entirely — which is a
# worse bug to debug than the one it would be reporting.
for _s in viaclient perm accept; do
  cx_run "$HOME_DIR" stop "cx-test-web1:api@$_s" >/dev/null 2>&1
done

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

describe "a target narrows both output paths, not just the table"
# The table filtered and --json did not, so `cx peek <target> --json` answered
# with every session on the host. A driver taking .sessions[0] then read a
# different session's transcript and believed it — silent, and wrong.

agent "open api --session other --detach --mode continue" >/dev/null 2>&1

it "the table shows only the asked-for session"
assert_eq \
  "$(cx_run "$HOME_DIR" peek cx-test-web1:api@impl | grep -c 'api@other')" \
  0

it "--json shows only the asked-for session too"
assert_eq \
  "$(cx_run "$HOME_DIR" --json peek cx-test-web1:api@impl | jq -r '.sessions[].target')" \
  "api@impl"

it "a bare project still covers its labelled sessions"
assert_eq \
  "$(cx_run "$HOME_DIR" --json peek cx-test-web1:api | jq -r '.sessions | length')" \
  2

it "and no target still returns everything"
assert_eq \
  "$(cx_run "$HOME_DIR" --json peek | jq -r '.sessions | length')" \
  2

cx_run "$HOME_DIR" stop cx-test-web1:api@other >/dev/null 2>&1

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

describe "a long prompt is actually submitted, not left in the input box"
# tmux delivers the paste and the Enter immediately; the application drains
# them at its own pace. An Enter arriving while a large paste is still being
# read is absorbed INTO it, leaving the prompt complete and unsent while nudge
# reports success — the worst shape available, since a driver that trusts
# "sent" then waits forever. Found by a driver mid-run on a 30-line prompt,
# after dozens of shorter ones had landed.

_long=$(python3 -c "print('SUBMITTED-MARKER'); print()
print(chr(10).join('padding line %02d of a deliberately large paste' % i for i in range(1, 61)))" 2>/dev/null ||
  awk 'BEGIN { print "SUBMITTED-MARKER"; print ""
    for (i = 1; i <= 60; i++) printf "padding line %02d of a deliberately large paste\n", i }')

printf '%s' "$_long" | cx_run "$HOME_DIR" nudge cx-test-web1:api@impl >/dev/null 2>&1
settle 4

it "reaches the session rather than parking in the input box"
# -S -3000 reaches into the scrollback: the stub echoes every line it is given,
# so a 60-line paste pushes the marker off the visible pane before this runs.
assert_contains \
  "$(on_node 'tmux capture-pane -pJ -S -3000 -t "=cx-api@impl:"')" \
  "SUBMITTED-MARKER"

it "leaves nothing pending"
assert_eq \
  "$(on_node 'tmux capture-pane -pJ -S -3000 -t "=cx-api@impl:" | grep -c "Pasted text #"')" \
  0

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
