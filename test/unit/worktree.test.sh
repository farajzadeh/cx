#!/usr/bin/env bash
# Unit tests for merged worktrees: the `merged` fact in list and worktree list,
# and `worktree rm --merged`, against real git repositories.
#
# `--merged` deletes directories, so what matters most is what it will not
# delete: a branch with a commit the project does not have, a worktree with
# uncommitted changes, a worktree with a session running in it. Each gets a
# fixture, and each must survive with a reason.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-worktree.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export CX_DATA_DIR="$TMP/data" CX_CLAUDE_DIR="$TMP/claude"
export CX_REGISTRY="$TMP/data/projects.json" CX_SESSIONS="$TMP/data/sessions.json"
export CX_GOALS="$TMP/data/goals.json" CX_STATE_DIR="$TMP/data/state"
export CX_AGENT_NO_MAIN=1
mkdir -p "$CX_DATA_DIR"

# shellcheck source=../../server/cx-agent
. "$ROOT/server/cx-agent"
set +eu

if ! have jq || ! have git; then
  describe "merged worktrees"
  it "needs jq and git"
  skip "jq or git unavailable"
  summary
  exit $?
fi

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# No tmux here: the machine running the tests may have real sessions, and the
# one fixture that needs a running session gets it from _unit_sessions below.
have() {
  [ "$1" = tmux ] && return 1
  command -v "$1" >/dev/null 2>&1
}
LIVE_UNIT=""
_unit_sessions() { [ -n "$LIVE_UNIT" ] && [ "$1" = "$LIVE_UNIT" ] && printf 'cx-%s\n' "$1"; }

P="$TMP/projects/api"
W="$TMP/projects/.worktrees/api"
mkdir -p "$P" "$W"
g() { git -C "$1" "${@:2}" >/dev/null 2>&1; }
g "$P" init
g "$P" symbolic-ref HEAD refs/heads/main
printf 'one\n' >"$P/f"
g "$P" add f
g "$P" commit -m one

# landed: a commit that main then took in.
g "$P" worktree add -b landed "$W/landed"
printf 'landed\n' >"$W/landed/d"
g "$W/landed" add d
g "$W/landed" commit -m landed
g "$P" merge --ff-only landed

# wip: a commit main does not have.
g "$P" worktree add -b wip "$W/wip"
printf 'wip\n' >"$W/wip/w"
g "$W/wip" add w
g "$W/wip" commit -m wip

# fresh: made from main, nothing committed on it — nothing to lose.
g "$P" worktree add -b fresh "$W/fresh"

# dirty: merged, but with a change nobody committed.
g "$P" worktree add -b dirty "$W/dirty"
printf 'unsaved\n' >"$W/dirty/u"

# live: merged, with a session running in it.
g "$P" worktree add -b live "$W/live"

printf '{"version":1,"root":"%s","projects":[{"name":"api","path":"%s"}]}\n' "$TMP/projects" "$P" >"$CX_REGISTRY"

describe "merged — in cx-agent list"

LIST=$(cmd_list)
merged() { jq -r --arg n "$1" '.projects[0].worktrees[] | select(.name == $n) | .merged' <<<"$LIST"; }

it "calls a branch merged once the project's branch contains it"
assert_eq "$(merged landed)" true

it "does not call a branch with its own commits merged"
assert_eq "$(merged wip)" false

it "calls a branch with nothing on it merged, since removing it loses nothing"
assert_eq "$(merged fresh)" true

describe "merged — in cx-agent worktree list"

it "reports it there too"
assert_eq "$(_wt_list api | jq -r '.worktrees[] | select(.name == "wip") | .merged')" false

describe "worktree rm --merged"

LIVE_UNIT="api/live"
OUT=$(cmd_worktree rm api --merged 2>/dev/null)
RC=$?
kept_reason() { jq -r --arg n "$1" '.kept[] | select(.name == $n) | .reason' <<<"$OUT"; }

it "succeeds"
assert_eq "$RC" 0

it "removes what is merged, clean and idle"
assert_eq "$(jq -r '.removed | sort | join(",")' <<<"$OUT")" "fresh,landed"

it "really removes those directories"
assert_fail test -d "$W/landed"

it "keeps their branches"
assert_ok git -C "$P" show-ref --verify --quiet refs/heads/landed

it "keeps a branch with commits the project does not have"
assert_contains "$(kept_reason wip)" "commits"

it "keeps a worktree with uncommitted changes"
assert_contains "$(kept_reason dirty)" "uncommitted"

it "keeps a worktree with a session running in it"
assert_contains "$(kept_reason live)" "running"

it "leaves every kept directory where it was"
assert_ok test -d "$W/wip"

it "prints only JSON, so git's own chatter cannot corrupt it"
assert_ok jq -e . <<<"$OUT"

it "refuses --merged together with a worktree name"
(cmd_worktree rm api wip --merged) >/dev/null 2>&1
assert_eq "$?" 3

summary
