#!/usr/bin/env bash
# Integration tests for session commands and cx ask.
#
# `cx open` attaches a terminal, which a test harness cannot do — so these
# drive the agent's open path directly (exactly what the client invokes) and
# assert on the resulting tmux state. That covers the logic that actually
# matters: creating once, not stacking a second Claude, and choosing the right
# Claude invocation per mode.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"
# shellcheck source=lib/nodes.sh
. "$ROOT/test/integration/lib/nodes.sh"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  describe "sessions integration"
  it "requires Docker"
  skip "docker unavailable"
  summary
  exit $?
fi

nodes_build || {
  describe "sessions integration"
  it "builds the node image"
  _t_no "$_T_NAME" "docker build failed"
  summary
  exit 1
}

HOME_DIR=$(nodes_env)
trap 'nodes_cleanup "$HOME_DIR"' EXIT

P1=$(nodes_start web1 "$HOME_DIR") || {
  describe "sessions integration"
  it "starts a node"
  _t_no "$_T_NAME" "failed"
  summary
  exit 1
}
nodes_add_host "$HOME_DIR" cx-test-web1 "$P1"
cx_run "$HOME_DIR" provision cx-test-web1 >/dev/null 2>&1
cx_run "$HOME_DIR" new cx-test-web1:api >/dev/null 2>&1
cx_run "$HOME_DIR" new cx-test-web1:web >/dev/null 2>&1

NODE="${CX_NODE_PREFIX}web1"
on_node() { docker exec "$NODE" su - cxuser -c "$1" 2>&1; }
agent() { on_node "\$HOME/.local/bin/cx-agent $1"; }

# ---------------------------------------------------------------------------

describe "cx status with nothing running"

_out=$(cx_run "$HOME_DIR" status)

it "says so plainly"
assert_contains "$_out" 'No live sessions'

it "suggests how to start one"
assert_contains "$_out" 'cx open'

# ---------------------------------------------------------------------------

describe "opening a project creates a session and starts Claude"

agent 'open api --mode continue' >/dev/null 2>&1
sleep 1

it "creates the tmux session"
assert_contains "$(on_node 'tmux has-session -t cx-api && echo yes || echo no')" 'yes'

it "names it with the cx- prefix so cx status can find it"
assert_contains "$(on_node 'tmux list-sessions -F "#{session_name}"')" 'cx-api'

it "runs claude --continue in the project directory"
assert_contains "$(on_node 'tmux capture-pane -p -t cx-api')" 'continuing session in /home/cxuser/projects/api'

# ---------------------------------------------------------------------------

describe "re-opening does not stack a second Claude"

# The property that makes cx open safe to run repeatedly. The naive
# implementation sends the claude command every time and you end up with
# Claude running inside Claude.
agent 'open api --mode continue' >/dev/null 2>&1
sleep 1

it "still has exactly one Claude invocation in the pane"
assert_eq "$(on_node 'tmux capture-pane -p -t cx-api | grep -c "continuing session"')" '1'

it "still has exactly one tmux session"
assert_eq "$(on_node 'tmux list-sessions | wc -l' | tr -d ' ')" '1'

# ---------------------------------------------------------------------------

describe "modes choose different Claude invocations"

agent 'open web --mode resume' >/dev/null 2>&1
sleep 1

it "resume mode starts the session picker"
assert_contains "$(on_node 'tmux capture-pane -p -t cx-web')" 'resume picker'

on_node 'tmux kill-session -t cx-web' >/dev/null 2>&1
agent 'open web --mode shell' >/dev/null 2>&1
sleep 1

it "shell mode starts no Claude at all"
assert_not_contains "$(on_node 'tmux capture-pane -p -t cx-web')" 'STUB'

it "but still creates the session"
assert_contains "$(on_node 'tmux has-session -t cx-web && echo yes || echo no')" 'yes'

# ---------------------------------------------------------------------------

describe "cx status reports live sessions"

_out=$(cx_run "$HOME_DIR" status)

it "lists a running project"
assert_contains "$_out" 'api'

it "reports whether anyone is attached"
assert_contains "$_out" 'detached'

it "attributes the session to its host"
assert_contains "$_out" 'cx-test-web1'

# ---------------------------------------------------------------------------

describe "cx ls marks live projects"

_out=$(cx_run "$HOME_DIR" -r ls)

it "shows the live marker"
assert_contains "$_out" '●'

# ---------------------------------------------------------------------------

describe "cx stop"

_out=$(cx_run "$HOME_DIR" stop cx-test-web1:api)

it "reports the session stopped"
assert_contains "$_out" 'stopped cx-test-web1:api'

it "actually kills the tmux session"
assert_contains "$(on_node 'tmux has-session -t cx-api 2>/dev/null && echo yes || echo no')" 'no'

_out=$(cx_run "$HOME_DIR" stop cx-test-web1:api)
it "stopping an already-stopped project is not an error"
assert_contains "$_out" 'no live session'

run_rc cx_run "$HOME_DIR" stop cx-test-web1:api
it "and exits 0"
assert_eq "$_T_RC" 0

# ---------------------------------------------------------------------------

describe "cx ask"

_out=$(cx_run "$HOME_DIR" ask cx-test-web1:api "what is 2+2?")

it "returns the answer on stdout"
assert_contains "$_out" 'STUB_ANSWER: what is 2+2?'

it "creates no tmux session"
assert_contains "$(on_node 'tmux has-session -t cx-api 2>/dev/null && echo yes || echo no')" 'no'

# The reason the prompt travels on stdin rather than argv.
_out=$(cx_run "$HOME_DIR" ask cx-test-web1:api 'what is $HOME and "quotes" and $(whoami)?')

it "passes shell metacharacters through untouched"
assert_contains "$_out" '$HOME and "quotes" and $(whoami)?'

_out=$(printf 'piped question' | cx_run "$HOME_DIR" ask cx-test-web1:api)

it "reads the prompt from stdin when none is given"
assert_contains "$_out" 'STUB_ANSWER: piped question'

_out=$(printf 'line one\nline two\n' | cx_run "$HOME_DIR" ask cx-test-web1:api)

it "handles a multi-line prompt"
assert_contains "$_out" 'line two'

_out=$(cx_run "$HOME_DIR" ask cx-test-web1:nosuchproject "hi" 2>&1)

it "reports an unknown project clearly"
assert_contains "$_out" 'no such project'

# ---------------------------------------------------------------------------

describe "completion targets"

cx_run "$HOME_DIR" ls >/dev/null 2>&1

it "writes a targets file"
assert_ok test -s "$HOME_DIR/.cache/cx/targets"

it "contains host:project pairs"
assert_contains "$(cat "$HOME_DIR/.cache/cx/targets")" 'cx-test-web1:api'

_out=$(CX_CACHE_DIR="$HOME_DIR/.cache/cx" CX_SSHD_DIR="$HOME_DIR/.config/cx/ssh.d" \
  bash -c '. "'"$ROOT"'/completions/cx.bash"
    COMP_WORDS=(cx open ""); COMP_CWORD=2; _cx; printf "%s" "${COMPREPLY[*]}"')

it "bash completion offers targets without touching the network"
assert_contains "$_out" 'cx-test-web1:api'

summary
