#!/usr/bin/env bash
# Integration tests for host management and provisioning over real SSH.
#
# These run against throwaway sshd containers with real key auth, so they
# exercise the transport, the quoting, sudo package installation, and the
# agent — none of which a unit test can reach.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"
# shellcheck source=lib/nodes.sh
. "$ROOT/test/integration/lib/nodes.sh"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  describe "host management integration"
  it "requires Docker"
  skip "docker unavailable"
  summary
  exit $?
fi

nodes_build || {
  describe "host management integration"
  it "builds the test node image"
  _t_no "$_T_NAME" "docker build failed"
  summary
  exit 1
}

HOME_DIR=$(nodes_env)
trap 'nodes_cleanup "$HOME_DIR"' EXIT

PORT1=$(nodes_start web1 "$HOME_DIR") || {
  describe "host management integration"
  it "starts a test node"
  _t_no "$_T_NAME" "could not start sshd container"
  summary
  exit 1
}
PORT2=$(nodes_start web2 "$HOME_DIR") || PORT2=""

nodes_add_host "$HOME_DIR" cx-test-web1 "$PORT1"
[ -n "$PORT2" ] && nodes_add_host "$HOME_DIR" cx-test-web2 "$PORT2"

# ---------------------------------------------------------------------------

describe "cx host ls"

_out=$(cx_run "$HOME_DIR" host ls)

it "lists a configured host"
assert_contains "$_out" 'cx-test-web1'

it "resolves the address through ssh's own config resolution"
assert_contains "$_out" 'cxuser@127.0.0.1'

it "reports the host as cx-managed"
assert_contains "$_out" 'managed'

_out=$(cx_run "$HOME_DIR" --json host ls)

it "emits valid JSON with --json"
assert_ok bash -c "printf '%s' '$_out' | jq -e . >/dev/null"

# ---------------------------------------------------------------------------

describe "cx host test before provisioning"

_out=$(cx_run "$HOME_DIR" host test cx-test-web1)

it "connects successfully"
assert_contains "$_out" 'connected'

it "reports the agent as missing"
assert_contains "$_out" 'not installed'

it "tells the user how to fix it"
assert_contains "$_out" 'cx provision'

# ---------------------------------------------------------------------------

describe "cx provision"

_out=$(cx_run "$HOME_DIR" provision cx-test-web1)

it "uploads and runs bootstrap"
assert_contains "$_out" 'uploading'

it "installs the missing packages"
assert_contains "$_out" 'installing via apt-get'

it "reports the installed agent version"
assert_contains "$_out" 'agent:   0.1.0'

it "reports the project root it configured"
assert_contains "$_out" 'root:    projects'

it "detects Claude Code but flags that no one has signed in"
assert_contains "$_out" 'NOT SIGNED IN'

it "points at the sign-in command"
assert_contains "$_out" 'cx login'

# ---------------------------------------------------------------------------

describe "cx provision is idempotent"

_out=$(cx_run "$HOME_DIR" provision cx-test-web1)

it "installs nothing the second time"
assert_contains "$_out" 'all present'

it "does not invoke sudo when nothing is missing"
assert_contains "$_out" 'sudo not needed'

it "still reports a healthy agent"
assert_contains "$_out" 'agent:   0.1.0'

# ---------------------------------------------------------------------------

describe "cx host test after provisioning"

_out=$(cx_run "$HOME_DIR" host test cx-test-web1)

it "finds the agent"
assert_contains "$_out" 'agent... ✓ 0.1.0'

it "reports the Claude Code version from the server"
assert_contains "$_out" 'Claude Code stub'

it "reports a valid registry"
assert_contains "$_out" 'registry: ok'

# ---------------------------------------------------------------------------

describe "Claude Code is found even though it is not on the non-interactive PATH"

# Regression guard. cx invokes the agent as `ssh host '...cx-agent doctor'`,
# a non-interactive non-login shell that reads neither ~/.bashrc nor
# ~/.profile — so ~/.local/bin, where Claude Code installs itself, is absent
# from PATH. `command -v claude` therefore fails on a server where Claude is
# installed and signed in, and cx used to report "not installed".

_path_out=$(ssh -F "$HOME_DIR/.ssh/config" -o BatchMode=yes cx-test-web1 \
  'command -v claude || echo NOTFOUND' 2>&1)

it "confirms the test really is exercising the hard case"
assert_contains "$_path_out" 'NOTFOUND'

_out=$(cx_run "$HOME_DIR" host test cx-test-web1)

it "reports Claude Code as installed anyway"
assert_not_contains "$_out" 'claude:  not installed'

it "reads its version"
assert_contains "$_out" 'Claude Code stub'

_doctor=$(ssh -F "$HOME_DIR/.ssh/config" -o BatchMode=yes cx-test-web1 \
  '$HOME/.local/bin/cx-agent doctor' 2>/dev/null)

it "resolves an absolute path to the binary"
assert_contains "$_doctor" '/home/cxuser/.local/bin/claude'

it "and marks it installed in the JSON"
assert_eq "$(printf '%s' "$_doctor" | jq -r '.claude.installed')" 'true'

# ---------------------------------------------------------------------------

describe "cx doctor"

_out=$(cx_run "$HOME_DIR" doctor)

it "checks the local machine"
assert_contains "$_out" 'This machine'

it "confirms the ssh Include is wired up"
assert_contains "$_out" 'ssh Include configured'

it "reports each server's agent state"
assert_contains "$_out" 'agent 0.1.0'

# ---------------------------------------------------------------------------

describe "unreachable hosts fail fast with an explanation"

cat >"$HOME_DIR/.config/cx/ssh.d/cx-test-dead.conf" <<EOF
#cx:root=projects

Host cx-test-dead
    HostName 127.0.0.1
    User cxuser
    Port 1
    IdentityFile $HOME_DIR/.ssh/id_ed25519
EOF

_start=$(date +%s)
_out=$(cx_run "$HOME_DIR" host test cx-test-dead)
_elapsed=$(($(date +%s) - _start))

it "classifies the failure rather than reporting a generic error"
assert_contains "$_out" 'refused'

it "explains what to check"
assert_contains "$_out" 'sshd running'

it "gives up quickly rather than hanging"
assert_ok test "$_elapsed" -lt 15

rm -f "$HOME_DIR/.config/cx/ssh.d/cx-test-dead.conf"

# ---------------------------------------------------------------------------

describe "unknown hosts are rejected clearly"

_out=$(cx_run "$HOME_DIR" host test nope-not-a-host)

it "reports the host as unknown"
assert_contains "$_out" 'unknown host'

run_rc cx_run "$HOME_DIR" host test nope-not-a-host
it "exits 2 for a missing target"
assert_eq "$_T_RC" 2

# ---------------------------------------------------------------------------

describe "cx host rm"

if [ -n "$PORT2" ]; then
  _out=$(cx_run "$HOME_DIR" host rm cx-test-web2)

  it "removes the host"
  assert_contains "$_out" 'removed cx-test-web2'

  it "no longer lists it"
  assert_not_contains "$(cx_run "$HOME_DIR" host ls)" 'cx-test-web2'

  it "leaves the other host alone"
  assert_contains "$(cx_run "$HOME_DIR" host ls)" 'cx-test-web1'
else
  it "second node available"
  skip "could not start a second node"
fi

summary
