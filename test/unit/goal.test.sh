#!/usr/bin/env bash
# Unit tests for the goal store in server/cx-agent.
#
# Reachable as unit tests because of the CX_AGENT_NO_MAIN seam: the agent is
# sourced for its functions, pointed at a scratch data directory, and driven
# directly. Nothing here touches a real registry, a real goals file, or the
# network.
#
# What is worth pinning here is the part that is easy to get quietly wrong —
# that changing a definition of done keeps the old one, that pausing does not
# disturb anything else, and that the history cannot grow without bound.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

# shellcheck source=../../lib/compat.sh
. "$ROOT/lib/compat.sh"

if ! cx_have jq; then
  describe "goal store"
  it "needs jq"
  skip "jq unavailable"
  summary
  exit $?
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-goal.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export CX_DATA_DIR="$TMP/data" CX_CLAUDE_DIR="$TMP/claude"
export CX_REGISTRY="$TMP/data/projects.json" CX_SESSIONS="$TMP/data/sessions.json"
export CX_GOALS="$TMP/data/goals.json"
export CX_AGENT_NO_MAIN=1
# shellcheck source=../../server/cx-agent
. "$ROOT/server/cx-agent"
# The agent runs under `set -eu`, and sourcing it brings that along. A test
# file deliberately calls things that fail, so turn it back off here.
set +eu

# The agent writes to stderr on the way out of `die`; quiet it so a
# deliberately invalid call does not look like a failure.
log() { :; }

# goal ... — cmd_goal in a subshell, since `die` exits.
goal() { (cmd_goal "$@") 2>/dev/null; }
goal_rc() { (cmd_goal "$@") >/dev/null 2>&1; }
# with_stdin TEXT SUBCOMMAND... — a goal call whose payload arrives on stdin,
# runnable by assert_exit (which takes a command, not a pipeline).
with_stdin() {
  local text="$1"
  shift
  printf '%s' "$text" | (cmd_goal "$@") >/dev/null 2>&1
}
field() { goal show "$1" | jq -r "$2"; }

mkdir -p "$TMP/data"

# ---------------------------------------------------------------------------

describe "creating a goal"

it "stores the definition of done verbatim"
printf 'tests green, PR open' | goal new ship >/dev/null
assert_eq "$(field ship .dod)" "tests green, PR open"

it "starts active"
assert_eq "$(field ship .state)" active

it "starts with no members"
assert_eq "$(field ship '.members | length')" 0

it "records when it was created"
assert_ne "$(field ship .created_at)" ""

it "keeps a multi-line definition of done intact"
printf 'line one\nline two\nline three' | goal new multi >/dev/null
assert_eq "$(field multi '.dod | split("\n") | length')" 3

it "refuses a second goal with the same name"
assert_exit 4 with_stdin x new ship

it "refuses an empty definition of done"
assert_exit 3 with_stdin "" new empty-one

it "refuses a dot in the name, which tmux would mangle"
assert_exit 3 with_stdin x new my.goal

it "refuses a name with a space"
assert_exit 3 with_stdin x new "two words"

describe "changing the definition of done keeps the old one"

it "replaces the text"
printf 'tests green only' | goal dod ship >/dev/null
assert_eq "$(field ship .dod)" "tests green only"

it "records a revision"
assert_eq "$(field ship '.revisions | length')" 1

it "remembers what it used to say"
assert_eq "$(field ship '.revisions[0].from')" "tests green, PR open"

it "names the field that changed"
assert_eq "$(field ship '.revisions[0].field')" dod

describe "pausing"

it "sets the state"
goal state ship paused >/dev/null
assert_eq "$(field ship .state)" paused

it "records the change"
assert_eq "$(field ship '.revisions[-1].from')" active

it "leaves the definition of done alone"
assert_eq "$(field ship .dod)" "tests green only"

it "resumes"
goal state ship active >/dev/null
assert_eq "$(field ship .state)" active

it "refuses a state that is not one of the three"
assert_fail goal_rc state ship halfway

describe "members"

it "accepts a member on another host without checking it"
# This server cannot see web2, and invariant 1 says it must not try. Storing
# the string as written is what lets one goal span servers.
goal member add ship web2:api/authfix >/dev/null
assert_eq "$(field ship '.members[0]')" web2:api/authfix

it "does not duplicate a member added twice"
goal member add ship web2:api/authfix >/dev/null
assert_eq "$(field ship '.members | length')" 1

it "removes one"
goal member rm ship web2:api/authfix >/dev/null
assert_eq "$(field ship '.members | length')" 0

it "rejects a local member that does not exist"
assert_exit 2 goal_rc member add ship no-such-project

describe "the log"

it "records an entry"
printf 'nudged it' | goal log ship --event nudge --target api@impl >/dev/null
assert_eq "$(field ship '.log[-1].text')" "nudged it"

it "keeps the event name"
assert_eq "$(field ship '.log[-1].event')" nudge

it "keeps the target"
assert_eq "$(field ship '.log[-1].target')" api@impl

it "leaves the target null when there is none"
printf 'just a note' | goal log ship >/dev/null
assert_eq "$(field ship '.log[-1].target')" null

describe "history cannot grow without bound"

it "caps the log at CX_GOAL_HISTORY entries"
i=0
while [ "$i" -lt 60 ]; do
  printf 'entry %s' "$i" | goal log ship >/dev/null
  i=$((i + 1))
done
assert_eq "$(field ship '.log | length')" "$CX_GOAL_HISTORY"

it "keeps the newest entries, not the oldest"
assert_eq "$(field ship '.log[-1].text')" "entry 59"

describe "listing"

it "reports every goal"
assert_eq "$(goal ls | jq -r '.goals | length')" 2

it "filters by state"
goal state multi paused >/dev/null
assert_eq "$(goal ls --state paused | jq -r '.goals | length')" 1

it "filters out the others"
assert_eq "$(goal ls --state active | jq -r '.goals[0].name')" ship

describe "removing"

it "removes the goal"
goal rm multi >/dev/null
assert_eq "$(goal ls | jq -r '.goals | length')" 1

it "reports a goal that is not there as not found"
assert_exit 2 goal_rc show multi

it "will not remove one twice"
assert_exit 2 goal_rc rm multi

describe "a member that goes away is dropped, but the goal is not"
#
# _goal_forget runs when a project or worktree is removed, and is given that
# unit's LOCAL name. Members are seeded directly here because goal member add
# checks that a bare member exists, and this scratch server has no registry.

# shellcheck disable=SC2016
_goal_apply ship '.members = ["api", "api/authfix", "api@review", "web2:api"]' >/dev/null
_goal_forget api

it "drops the unit itself"
assert_not_contains "$(field ship '.members | join(",")')" '"api"'

it "drops its worktrees"
assert_not_contains "$(field ship '.members | join(",")')" 'api/authfix'

it "drops its labelled sessions"
assert_not_contains "$(field ship '.members | join(",")')" 'api@review'

it "leaves the same name on another server alone"
# This server cannot know anything about web2's api, and invariant 1 says it
# must not go and look.
assert_eq "$(field ship '.members | join(",")')" web2:api

it "keeps the goal itself when a member disappears"
# Losing one of two sessions does not mean the work is over, and deleting the
# user's stated intent on their behalf would be the wrong call.
assert_eq "$(field ship .state)" active

describe "the goals file survives a reader that finds nothing"

it "creates a valid empty file on first use"
rm -f "$CX_GOALS"
_goals_ensure
assert_eq "$(jq -r '.goals | length' "$CX_GOALS")" 0

it "reports no such goal rather than failing on an empty store"
assert_exit 2 goal_rc show anything

summary
