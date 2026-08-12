#!/usr/bin/env bash
# Integration tests for `cx new` and `cx ls` against two real servers.
#
# Two servers, not one: fan-out merging, per-host attribution, and name
# ambiguity are all invisible with a single host.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"
# shellcheck source=lib/nodes.sh
. "$ROOT/test/integration/lib/nodes.sh"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  describe "projects integration"
  it "requires Docker"
  skip "docker unavailable"
  summary
  exit $?
fi

nodes_build || {
  describe "projects integration"
  it "builds the node image"
  _t_no "$_T_NAME" "docker build failed"
  summary
  exit 1
}

HOME_DIR=$(nodes_env)
trap 'nodes_cleanup "$HOME_DIR"' EXIT

P1=$(nodes_start web1 "$HOME_DIR") || {
  describe "projects integration"
  it "starts node 1"
  _t_no "$_T_NAME" "failed"
  summary
  exit 1
}
P2=$(nodes_start web2 "$HOME_DIR") || {
  describe "projects integration"
  it "starts node 2"
  _t_no "$_T_NAME" "failed"
  summary
  exit 1
}

nodes_add_host "$HOME_DIR" cx-test-web1 "$P1"
nodes_add_host "$HOME_DIR" cx-test-web2 "$P2"
cx_run "$HOME_DIR" provision --all >/dev/null 2>&1

# ---------------------------------------------------------------------------

describe "cx new"

_out=$(cx_run "$HOME_DIR" new cx-test-web1:api)

it "reports success"
assert_contains "$_out" 'created cx-test-web1:api'

it "shows where the project landed on the server"
assert_contains "$_out" '/home/cxuser/projects/api'

it "suggests the obvious next command"
assert_contains "$_out" 'cx open cx-test-web1:api'

run_rc cx_run "$HOME_DIR" new cx-test-web1:site
it "exits 0 on success"
assert_eq "$_T_RC" 0

_out=$(cx_run "$HOME_DIR" --json new cx-test-web1:jsontest)

it "emits one compact JSON object with --json"
assert_eq "$(printf '%s' "$_out" | grep -c '^{')" '1'

it "includes the host in JSON output"
assert_contains "$_out" '"host":"cx-test-web1"'

# ---------------------------------------------------------------------------

describe "cx new rejects bad input"

_out=$(cx_run "$HOME_DIR" new cx-test-web1:api 2>&1)
it "refuses a duplicate name"
assert_contains "$_out" 'already exists'

run_rc cx_run "$HOME_DIR" new cx-test-web1:api
it "exits 4 on conflict, distinctly from other errors"
assert_eq "$_T_RC" 4

# '/' is target syntax (it selects a worktree), so cx new rejects it in the
# client rather than letting the component be parsed off and dropped.
_out=$(cx_run "$HOME_DIR" new "cx-test-web1:../escape" 2>&1)
it "rejects a name containing a path separator"
assert_contains "$_out" "cannot contain '/' or '@'"

run_rc cx_run "$HOME_DIR" new "cx-test-web1:../escape"
it "and exits 3 (usage), not by creating something"
assert_eq "$_T_RC" 3

it "created nothing on the server"
assert_not_contains "$(cx_run "$HOME_DIR" -r ls cx-test-web1)" 'escape'

# The agent is the backstop: it rejects a traversal attempt even when the
# client's parsing is bypassed entirely.
_out=$(docker exec "${CX_NODE_PREFIX}web1" su - cxuser \
  -c '$HOME/.local/bin/cx-agent new ../escape' 2>&1)
it "the agent rejects a path separator independently of the client"
assert_contains "$_out" 'cannot contain spaces, tabs or slashes'

_out=$(docker exec "${CX_NODE_PREFIX}web1" su - cxuser \
  -c '$HOME/.local/bin/cx-agent new ..' 2>&1)
it "and rejects a bare .. that has no separator to catch it"
assert_contains "$_out" 'invalid project name'

_out=$(cx_run "$HOME_DIR" new nosuchhost:thing 2>&1)
it "rejects an unknown host"
assert_contains "$_out" 'unknown host'

_out=$(cx_run "$HOME_DIR" new bare-name 2>&1)
it "explains that a bare name needs CX_DEFAULT_HOST"
assert_contains "$_out" 'CX_DEFAULT_HOST'

# ---------------------------------------------------------------------------

describe "cx new --repo clones"

docker exec "${CX_NODE_PREFIX}web1" su - cxuser -c '
  git config --global user.email t@t
  git config --global user.name t
  git config --global init.defaultBranch main
  rm -rf /tmp/seed /tmp/origin
  mkdir -p /tmp/seed && cd /tmp/seed && git init -q
  echo hello > README.md && git add -A && git commit -qm init
  git clone -q --bare /tmp/seed /tmp/origin' >/dev/null 2>&1

_out=$(cx_run "$HOME_DIR" new cx-test-web1:cloned --repo /tmp/origin)

it "reports the clone"
assert_contains "$_out" 'created cx-test-web1:cloned'

_files=$(docker exec "${CX_NODE_PREFIX}web1" su - cxuser -c 'ls ~/projects/cloned' 2>&1)
it "actually brings the files down"
assert_contains "$_files" 'README.md'

_remote=$(docker exec "${CX_NODE_PREFIX}web1" su - cxuser -c 'git -C ~/projects/cloned remote get-url origin' 2>&1)
it "records the remote git reports, not the argument we passed"
assert_contains "$_remote" '/tmp/origin'

# ---------------------------------------------------------------------------

describe "cx ls"

cx_run "$HOME_DIR" new cx-test-web2:api >/dev/null 2>&1
_out=$(cx_run "$HOME_DIR" ls)

it "lists projects from the first server"
assert_contains "$_out" 'cx-test-web1'

it "lists projects from the second server too"
assert_contains "$_out" 'cx-test-web2'

it "shows the branch of a cloned repo"
assert_contains "$_out" 'main'

it "names a fresh repo's branch rather than showing the literal HEAD"
assert_not_contains "$_out" 'HEAD'

it "renders the repo URL for cloned projects"
assert_contains "$_out" '/tmp/origin'

it "reports sessions as unknown when the Claude store does not exist yet"
assert_contains "$_out" '?'

# ---------------------------------------------------------------------------

describe "cx ls --git"

_out=$(cx_run "$HOME_DIR" ls --git)
it "reports a clean tree with no dirty marker"
assert_not_contains "$_out" '*'

docker exec "${CX_NODE_PREFIX}web1" su - cxuser -c 'echo change >> ~/projects/cloned/README.md' >/dev/null 2>&1
_out=$(cx_run "$HOME_DIR" ls --git)
it "marks a dirty working tree"
assert_contains "$_out" '*'

# ---------------------------------------------------------------------------

describe "cx ls --json"

_out=$(cx_run "$HOME_DIR" ls --json)

run_rc bash -c 'printf "%s" "$1" | jq -e . >/dev/null' _ "$_out"
it "is valid JSON"
assert_eq "$_T_RC" 0

it "reports which servers answered"
assert_contains "$_out" '"servers"'

it "attributes every project to its host"
assert_eq "$(printf '%s' "$_out" | jq -r '[.projects[] | select(.host == null)] | length')" '0'

# ---------------------------------------------------------------------------

describe "cx ls scoped to one host"

_out=$(cx_run "$HOME_DIR" ls cx-test-web1)
it "includes that host's projects"
assert_contains "$_out" 'cloned'
it "excludes other hosts"
assert_not_contains "$_out" 'cx-test-web2'

# ---------------------------------------------------------------------------

describe "a partial view announces itself"

cat >"$HOME_DIR/.config/cx/ssh.d/cx-test-dead.conf" <<EOF
#cx:root=projects

Host cx-test-dead
    HostName 127.0.0.1
    User cxuser
    Port 1
    IdentityFile $HOME_DIR/.ssh/id_ed25519
EOF

_out=$(cx_run "$HOME_DIR" ls)

it "still lists the reachable servers' projects"
assert_contains "$_out" 'cloned'

it "warns that a server is missing rather than silently omitting it"
assert_contains "$_out" 'unreachable'

it "names the server that failed"
assert_contains "$_out" 'cx-test-dead'

rm -f "$HOME_DIR/.config/cx/ssh.d/cx-test-dead.conf"

summary
