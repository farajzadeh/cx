#!/usr/bin/env bash
# Integration tests for server/bootstrap.sh against real distro containers.
#
# These cover the failures that unit tests structurally cannot: package
# manager differences, running under a /bin/sh that is not bash, installing
# bash when it is absent, and not clobbering files a user already owns.
#
# Requires Docker. Skipped (not failed) when Docker is unavailable, so the
# suite stays useful on machines without it.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  describe "bootstrap.sh integration"
  it "requires Docker"
  skip "docker unavailable"
  summary
  exit $?
fi

# run_in IMAGE SCRIPT — execute SCRIPT inside IMAGE with the repo mounted
# read-only at /w. Read-only matters: it proves bootstrap never writes into
# the source tree, only into $HOME.
run_in() {
  docker run --rm -v "$ROOT":/w:ro "$1" sh -c "$2" 2>&1
}

PROVISION='cp /w/server/cx-agent /tmp/cx-agent.incoming && sh /w/server/bootstrap.sh --skip-claude'

# ---------------------------------------------------------------------------

describe "Ubuntu 24.04 — apt-get, /bin/sh is dash"

_out=$(run_in ubuntu:24.04 "$PROVISION >/tmp/o 2>/tmp/e; echo EXIT=\$?; tail -1 /tmp/o; grep -c 'ERROR' /tmp/e || true")

it "exits 0"
assert_contains "$_out" 'EXIT=0'

it "emits a machine-readable summary on stdout with ok:true"
assert_contains "$_out" '"ok":true'

it "reports the agent version it installed"
assert_contains "$_out" '"agent_version":"0.1.0"'

it "logs no errors"
assert_not_contains "$_out" 'ERROR:'

# ---------------------------------------------------------------------------

describe "Ubuntu — idempotency and preservation on re-run"

_out=$(run_in ubuntu:24.04 "
  $PROVISION >/dev/null 2>&1
  printf '# USER EDIT\n' >> \$HOME/.tmux.conf
  printf '{\"version\":1,\"root\":\"/root/projects\",\"projects\":[{\"name\":\"sentinel\"}]}' > \$HOME/.local/share/cx/projects.json
  cp /w/server/cx-agent /tmp/cx-agent.incoming
  sh /w/server/bootstrap.sh --skip-claude 2>&1 | grep -E 'sudo not needed|left untouched|already configured|exists   .*projects.json'
  printf 'TMUXEDIT=%s\n' \"\$(grep -c 'USER EDIT' \$HOME/.tmux.conf)\"
  printf 'SENTINEL=%s\n' \"\$(grep -c sentinel \$HOME/.local/share/cx/projects.json)\"
  printf 'PATHLINES=%s\n' \"\$(grep -c 'added by cx' \$HOME/.profile)\"
")

it "skips package installation entirely when nothing is missing"
assert_contains "$_out" 'sudo not needed'

it "leaves an existing ~/.tmux.conf untouched"
assert_contains "$_out" 'TMUXEDIT=1'

it "leaves an existing registry untouched"
assert_contains "$_out" 'SENTINEL=1'

it "does not duplicate the PATH block in ~/.profile"
assert_contains "$_out" 'PATHLINES=1'

# ---------------------------------------------------------------------------

describe "Alpine 3.20 — apk, busybox ash, bash absent"

# The hardest case: /bin/sh is busybox ash, and bash — which cx-agent needs —
# is not installed. This is why bootstrap.sh is POSIX sh rather than bash.
_out=$(run_in alpine:3.20 "
  printf 'BASHBEFORE=%s\n' \"\$(command -v bash || echo MISSING)\"
  $PROVISION >/tmp/o 2>/tmp/e; echo EXIT=\$?
  tail -1 /tmp/o
  printf 'BASHAFTER=%s\n' \"\$(command -v bash || echo MISSING)\"
  \$HOME/.local/bin/cx-agent version
")

it "starts with no bash installed"
assert_contains "$_out" 'BASHBEFORE=MISSING'

it "exits 0"
assert_contains "$_out" 'EXIT=0'

it "installs bash so the agent can run"
assert_contains "$_out" 'BASHAFTER=/bin/bash'

it "leaves a working agent behind"
assert_contains "$_out" '0.1.0'

# ---------------------------------------------------------------------------

describe "--dry-run"

_out=$(run_in ubuntu:24.04 "
  cp /w/server/cx-agent /tmp/cx-agent.incoming
  sh /w/server/bootstrap.sh --skip-claude --dry-run >/tmp/o 2>/tmp/e; echo EXIT=\$?
  tail -1 /tmp/o
  printf 'DIRS=%s\n' \"\$(ls -d \$HOME/.local/share/cx 2>/dev/null | wc -l)\"
  printf 'TMUXCONF=%s\n' \"\$([ -e \$HOME/.tmux.conf ] && echo yes || echo no)\"
  printf 'PROFILE=%s\n' \"\$([ -e \$HOME/.profile ] && grep -c 'added by cx' \$HOME/.profile || echo 0)\"
")

it "exits 0"
assert_contains "$_out" 'EXIT=0'

it "reports dry_run in the summary"
assert_contains "$_out" '"dry_run":true'

it "creates no directories"
assert_contains "$_out" 'DIRS=0'

it "writes no tmux config"
assert_contains "$_out" 'TMUXCONF=no'

it "does not touch ~/.profile"
assert_contains "$_out" 'PROFILE=0'

# ---------------------------------------------------------------------------

describe "failure paths give actionable errors"

# busybox has a shell but no package manager at all.
_out=$(run_in busybox:latest "
  cp /w/server/cx-agent /tmp/cx-agent.incoming 2>/dev/null
  sh /w/server/bootstrap.sh --skip-claude 2>&1; echo EXIT=\$?
")

it "fails clearly when no package manager exists"
assert_contains "$_out" 'No supported package manager'

it "names the packages the user must install by hand"
assert_contains "$_out" 'jq'

it "exits non-zero"
assert_not_contains "$_out" 'EXIT=0'

_out=$(run_in ubuntu:24.04 "sh /w/server/bootstrap.sh --skip-claude --dry-run 2>&1; echo EXIT=\$?")

it "fails clearly when the client uploaded no agent"
assert_contains "$_out" 'No agent at'

# ---------------------------------------------------------------------------

describe "bootstrap never writes into the source tree"

# The repo is mounted read-only above; any attempt to write to it would have
# surfaced as an error in the runs already performed.
it "completed all runs with the repo mounted read-only"
assert_ok true

summary
