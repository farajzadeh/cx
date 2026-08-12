#!/usr/bin/env bash
# Integration tests for `cx wt` — git worktrees for parallel tasks.
#
# The properties under test, in order of how much they would hurt to get wrong:
#
#   * two worktrees are two directories on two branches, so parallel sessions
#     cannot overwrite each other
#   * cx stores nothing about them; `git worktree list` is the source of truth,
#     so a worktree made by hand shows up and one removed by hand disappears
#   * removal refuses to throw away uncommitted work, and refuses BEFORE it
#     kills any session
#   * removing the project takes its worktrees with it
#
# `cx open` needs a terminal, so session behavior is driven through the agent
# directly — exactly the argv the client sends.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"
# shellcheck source=lib/nodes.sh
. "$ROOT/test/integration/lib/nodes.sh"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  describe "worktrees integration"
  it "requires Docker"
  skip "docker unavailable"
  summary
  exit $?
fi

nodes_build || {
  describe "worktrees integration"
  it "builds the node image"
  _t_no "$_T_NAME" "docker build failed"
  summary
  exit 1
}

HOME_DIR=$(nodes_env)
trap 'nodes_cleanup "$HOME_DIR"' EXIT

P1=$(nodes_start web1 "$HOME_DIR") || {
  describe "worktrees integration"
  it "starts a node"
  _t_no "$_T_NAME" "failed"
  summary
  exit 1
}
nodes_add_host "$HOME_DIR" cx-test-web1 "$P1"
cx_run "$HOME_DIR" provision cx-test-web1 >/dev/null 2>&1
cx_run "$HOME_DIR" new cx-test-web1:api >/dev/null 2>&1

NODE="${CX_NODE_PREFIX}web1"
on_node() { docker exec "$NODE" su - cxuser -c "$1" 2>&1; }
agent() { on_node "\$HOME/.local/bin/cx-agent $1"; }

# git worktree add needs a commit to branch from.
on_node 'cd ~/projects/api && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init' >/dev/null 2>&1

# ---------------------------------------------------------------------------

describe "cx wt add"

_out=$(cx_run "$HOME_DIR" wt add cx-test-web1:api/authfix)

it "reports the worktree created"
assert_contains "$_out" 'created cx-test-web1:api/authfix'

it "names the branch it made"
assert_contains "$_out" 'authfix'

it "puts it in the hidden per-project directory beside the project"
assert_contains "$(on_node 'ls ~/projects/.worktrees/api')" 'authfix'

it "leaves the project root itself uncluttered"
assert_not_contains "$(on_node 'ls ~/projects')" 'authfix'

it "checks out the new branch there"
assert_eq "$(on_node 'git -C ~/projects/.worktrees/api/authfix rev-parse --abbrev-ref HEAD')" 'authfix'

it "leaves the main checkout on its own branch"
assert_ne "$(on_node 'git -C ~/projects/api rev-parse --abbrev-ref HEAD')" 'authfix'

_out=$(cx_run "$HOME_DIR" wt add cx-test-web1:api/authfix 2>&1)
it "refuses to create the same worktree twice"
assert_contains "$_out" 'already exists'

run_rc cx_run "$HOME_DIR" wt add cx-test-web1:api/authfix
it "and exits 4 (conflict)"
assert_eq "$_T_RC" 4

_out=$(cx_run "$HOME_DIR" wt add cx-test-web1:api/bug-123 --branch fix/bug-123 2>&1)

it "--branch decouples the branch name from the worktree name"
assert_eq "$(on_node 'git -C ~/projects/.worktrees/api/bug-123 rev-parse --abbrev-ref HEAD')" 'fix/bug-123'

it "so a branch name with a slash is still usable as a target"
assert_contains "$_out" 'created cx-test-web1:api/bug-123'

# ---------------------------------------------------------------------------

describe "cx wt add rejects what it cannot do"

_out=$(cx_run "$HOME_DIR" wt add cx-test-web1:api 2>&1)
it "requires a worktree component in the target"
assert_contains "$_out" 'no worktree named'

_out=$(cx_run "$HOME_DIR" wt add 'cx-test-web1:api/bad.name' 2>&1)
it "rejects a dot in the name (tmux would rewrite it)"
assert_contains "$_out" 'invalid worktree name'

_out=$(cx_run "$HOME_DIR" wt add cx-test-web1:nosuch/x 2>&1)
it "reports an unknown project clearly"
assert_contains "$_out" 'no such project'

cx_run "$HOME_DIR" new cx-test-web1:empty >/dev/null 2>&1
_out=$(cx_run "$HOME_DIR" wt add cx-test-web1:empty/x 2>&1)
it "explains that a repository with no commits cannot have a worktree"
assert_contains "$_out" 'no commits yet'

# ---------------------------------------------------------------------------

describe "cx wt ls"

_out=$(cx_run "$HOME_DIR" -r wt ls)

it "lists both worktrees"
assert_contains "$_out" 'api/authfix'

it "with their branches"
assert_contains "$_out" 'fix/bug-123'

_out=$(cx_run "$HOME_DIR" -r wt ls cx-test-web1:api)
it "can be filtered to one project"
assert_contains "$_out" 'api/bug-123'

_out=$(cx_run "$HOME_DIR" -r wt ls cx-test-web1:empty)
it "says so when a project has none"
assert_contains "$_out" 'No worktrees'

# ---------------------------------------------------------------------------

describe "worktrees are derived from git, never stored"

# The invariant that keeps cx from drifting: nothing about worktrees lives in
# the registry, so git is always right by construction.
it "the registry records no worktree data"
assert_not_contains "$(on_node 'cat ~/.local/share/cx/projects.json')" 'authfix'

on_node 'cd ~/projects/api && git worktree add -b byhand ~/projects/.worktrees/api/byhand' >/dev/null 2>&1
_out=$(cx_run "$HOME_DIR" -r wt ls cx-test-web1:api)

it "a worktree created by hand on the server shows up in cx"
assert_contains "$_out" 'api/byhand'

on_node 'cd ~/projects/api && git worktree remove ~/projects/.worktrees/api/byhand' >/dev/null 2>&1
_out=$(cx_run "$HOME_DIR" -r wt ls cx-test-web1:api)

it "and disappears again when removed by hand"
assert_not_contains "$_out" 'api/byhand'

# ---------------------------------------------------------------------------

describe "cx ls shows worktrees under their project"

_out=$(cx_run "$HOME_DIR" -r ls)

it "lists the project"
assert_contains "$_out" 'api'

it "lists its worktrees in the copy-pasteable target form"
assert_contains "$_out" 'api/authfix'

it "shows each worktree's own branch"
assert_contains "$_out" 'fix/bug-123'

# ---------------------------------------------------------------------------

describe "parallel sessions in separate worktrees"

agent 'open api --worktree authfix --mode continue' >/dev/null 2>&1
agent 'open api --worktree bug-123 --mode continue' >/dev/null 2>&1
sleep 1

it "each worktree gets its own tmux session"
assert_contains "$(on_node 'tmux list-sessions -F "#{session_name}" | sort | tr "\n" " "')" \
  'cx-api/authfix cx-api/bug-123'

# -J joins wrapped lines. Without it a path longer than the pane is split
# across two rows and a plain substring match fails on correct output.
it "each starts in its own directory"
assert_contains "$(on_node 'tmux capture-pane -pJ -t "=cx-api/authfix:"')" \
  '/home/cxuser/projects/.worktrees/api/authfix'

it "and they are genuinely different directories"
assert_contains "$(on_node 'tmux capture-pane -pJ -t "=cx-api/bug-123:"')" \
  '/home/cxuser/projects/.worktrees/api/bug-123'

it "with a separate pinned conversation for each"
assert_eq "$(on_node 'jq -r "[.sessions | keys[] | select(startswith(\"api/\"))] | length" ~/.local/share/cx/sessions.json')" '2'

# ---------------------------------------------------------------------------

describe "cx wt rm protects uncommitted work"

on_node 'echo scratch > ~/projects/.worktrees/api/authfix/notes.txt'
_out=$(cx_run "$HOME_DIR" wt rm cx-test-web1:api/authfix 2>&1)

it "refuses when the worktree is dirty"
assert_contains "$_out" 'uncommitted changes'

it "leaves the worktree in place"
assert_contains "$(on_node 'ls ~/projects/.worktrees/api')" 'authfix'

# Refusing AFTER killing the session would leave the user with their work
# stopped and the worktree still there — the worst of both outcomes.
it "and does not kill its session on the way to refusing"
assert_contains "$(on_node 'tmux has-session -t "=cx-api/authfix" 2>/dev/null && echo yes || echo no')" 'yes'

_out=$(cx_run "$HOME_DIR" wt rm cx-test-web1:api/authfix --force 2>&1)

it "--force removes it"
assert_contains "$_out" 'removed cx-test-web1:api/authfix'

it "the directory is gone"
assert_not_contains "$(on_node 'ls ~/projects/.worktrees/api')" 'authfix'

it "its tmux session is stopped"
assert_contains "$(on_node 'tmux has-session -t "=cx-api/authfix" 2>/dev/null && echo yes || echo no')" 'no'

it "the other worktree's session is untouched"
assert_contains "$(on_node 'tmux has-session -t "=cx-api/bug-123" 2>/dev/null && echo yes || echo no')" 'yes'

it "and its pinned conversation id is forgotten"
assert_not_contains "$(on_node 'cat ~/.local/share/cx/sessions.json')" 'api/authfix'

# Committed work must survive: the branch is kept deliberately.
it "keeps the branch, so nothing committed is lost"
assert_contains "$(on_node 'git -C ~/projects/api branch --list authfix')" 'authfix'

# ---------------------------------------------------------------------------

describe "cx rm takes a project's worktrees with it"

_out=$(cx_run "$HOME_DIR" rm cx-test-web1:api/bug-123 2>&1)
it "refuses to remove a worktree via cx rm"
assert_contains "$_out" 'not a worktree'

it "and points at the command that does"
assert_contains "$_out" 'cx wt rm'

cx_run "$HOME_DIR" rm cx-test-web1:api --purge >/dev/null 2>&1

it "purging the project removes its worktree directory"
assert_not_contains "$(on_node 'ls ~/projects/.worktrees 2>/dev/null || echo gone')" 'api'

it "and the project itself"
assert_not_contains "$(on_node 'ls ~/projects')" 'api'

it "and stops every session it had"
assert_eq "$(on_node 'tmux list-sessions -F "#{session_name}" 2>/dev/null | grep -c "^cx-api" || true' | tr -d ' \r')" '0'

summary
