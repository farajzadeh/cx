#!/usr/bin/env bash
# Integration tests for install.sh against a clean container.
#
# The install path is the first thing a stranger runs, and its failures are
# the expensive kind — a mangled ~/.ssh/config costs trust that a feature bug
# does not. These tests are correspondingly paranoid about what it touches.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  describe "install.sh integration"
  it "requires Docker"
  skip "docker unavailable"
  summary
  exit $?
fi

IMAGE=ubuntu:24.04
PREP='apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq git jq openssh-client >/dev/null 2>&1; cp -r /w /src; cd /src; rm -rf .git'

run_in() {
  docker run --rm -v "$ROOT":/w:ro "$IMAGE" bash -c "$PREP; $1" 2>&1
}

# ---------------------------------------------------------------------------

describe "fresh install"

_out=$(run_in '
  ./install.sh --yes >/dev/null 2>&1; echo "EXIT=$?"
  echo "SHIM=$([ -x ~/.local/bin/cx ] && echo yes || echo no)"
  echo "TREE=$([ -f ~/.local/share/cx/bin/cx ] && echo yes || echo no)"
  echo "CONFIG=$([ -f ~/.config/cx/config ] && echo yes || echo no)"
  echo "SSHDMODE=$(stat -c %a ~/.config/cx/ssh.d)"  # portable-ok: runs inside the ubuntu container
  echo "SSHMODE=$(stat -c %a ~/.ssh/config)"  # portable-ok: runs inside the ubuntu container
  echo "TESTDIR=$([ -d ~/.local/share/cx/test ] && echo leaked || echo excluded)"
  export PATH="$HOME/.local/bin:$PATH"
  echo "VERSION=$(cx --version)"
')

it "exits 2 (installed; VS Code absent in the container)"
assert_contains "$_out" 'EXIT=2'

it "installs the shim"
assert_contains "$_out" 'SHIM=yes'

it "installs the tree"
assert_contains "$_out" 'TREE=yes'

it "seeds a config from the template"
assert_contains "$_out" 'CONFIG=yes'

it "creates ssh.d with restrictive permissions"
assert_contains "$_out" 'SSHDMODE=700'

it "creates ~/.ssh/config with mode 600"
assert_contains "$_out" 'SSHMODE=600'

it "ships a runtime, not a working copy (no test/ directory)"
assert_contains "$_out" 'TESTDIR=excluded'

it "produces a runnable cx via the shim"
assert_contains "$_out" 'VERSION=cx 0.1.0'

# ---------------------------------------------------------------------------

describe "an existing ~/.ssh/config is respected"

_out=$(run_in '
  mkdir -p ~/.ssh
  printf "Host prod\n    HostName 10.0.0.1\n    User alice\n" > ~/.ssh/config
  chmod 600 ~/.ssh/config
  ORIG=$(cat ~/.ssh/config)
  ./install.sh --yes >/dev/null 2>&1
  echo "FIRSTLINE=$(grep -vE "^[[:space:]]*$" ~/.ssh/config | head -1)"
  echo "BACKUPS=$(ls ~/.ssh/config.cx-backup-* 2>/dev/null | wc -l | tr -d " ")"
  echo "BACKUPMATCH=$([ "$(cat ~/.ssh/config.cx-backup-*)" = "$ORIG" ] && echo yes || echo no)"
  echo "USERHOST=$(grep -c "Host prod" ~/.ssh/config)"
  echo "MODE=$(stat -c %a ~/.ssh/config)"  # portable-ok: runs inside the ubuntu container
')

it "puts Include first, where ssh's first-match-wins semantics need it"
assert_contains "$_out" 'FIRSTLINE=Include ~/.config/cx/ssh.d/*.conf'

it "takes exactly one backup"
assert_contains "$_out" 'BACKUPS=1'

it "backs up the file byte-for-byte before touching it"
assert_contains "$_out" 'BACKUPMATCH=yes'

it "preserves the user's own host definitions"
assert_contains "$_out" 'USERHOST=1'

it "leaves mode 600 intact"
assert_contains "$_out" 'MODE=600'

# ---------------------------------------------------------------------------

describe "re-running is safe and is the upgrade path"

_out=$(run_in '
  ./install.sh --yes >/dev/null 2>&1
  printf "CX_CACHE_TTL=99\n" >> ~/.config/cx/config
  ./install.sh --yes >/dev/null 2>&1; echo "EXIT=$?"
  echo "USEREDIT=$(grep -c "CX_CACHE_TTL=99" ~/.config/cx/config)"
  echo "INCLUDES=$(grep -c "cx/ssh.d" ~/.ssh/config)"
  echo "BACKUPS=$(ls ~/.ssh/config.cx-backup-* 2>/dev/null | wc -l | tr -d " ")"
')

it "succeeds on the second run"
assert_contains "$_out" 'EXIT=2'

it "never overwrites an edited config"
assert_contains "$_out" 'USEREDIT=1'

it "does not duplicate the Include line"
assert_contains "$_out" 'INCLUDES=1'

it "takes no further backup when there is nothing to change"
assert_contains "$_out" 'BACKUPS=0'

# ---------------------------------------------------------------------------

describe "uninstall removes cx and nothing else"

_out=$(run_in '
  mkdir -p ~/.ssh
  printf "Host prod\n    HostName 10.0.0.1\n" > ~/.ssh/config
  chmod 600 ~/.ssh/config
  ./install.sh --yes >/dev/null 2>&1
  ./install.sh --uninstall >/dev/null 2>&1; echo "EXIT=$?"
  echo "SHIM=$([ ! -e ~/.local/bin/cx ] && echo gone || echo present)"
  echo "TREE=$([ ! -d ~/.local/share/cx ] && echo gone || echo present)"
  echo "CONFIG=$([ -f ~/.config/cx/config ] && echo kept || echo destroyed)"
  echo "SSHD=$([ -d ~/.config/cx/ssh.d ] && echo kept || echo destroyed)"
  echo "INCLUDE=$(grep -c "cx/ssh.d" ~/.ssh/config; true)"
  echo "USERHOST=$(grep -c "Host prod" ~/.ssh/config)"
')

it "exits 0"
assert_contains "$_out" 'EXIT=0'

it "removes the shim"
assert_contains "$_out" 'SHIM=gone'

it "removes the tree"
assert_contains "$_out" 'TREE=gone'

it "keeps the user's config — uninstalling the client is not 'forget my servers'"
assert_contains "$_out" 'CONFIG=kept'

it "keeps the host definitions directory"
assert_contains "$_out" 'SSHD=kept'

it "removes its Include line"
assert_contains "$_out" 'INCLUDE=0'

it "leaves the user's own SSH hosts alone"
assert_contains "$_out" 'USERHOST=1'

# ---------------------------------------------------------------------------

describe "refuses to proceed when a required dependency is missing"

# alpine:3.20 has no jq, git, or ssh.
_out=$(docker run --rm -v "$ROOT":/w:ro alpine:3.20 sh -c '
  apk add --no-progress bash >/dev/null 2>&1
  bash /w/install.sh --yes >/dev/null 2>&1; echo "EXIT=$?"
  echo "SHIM=$([ -e ~/.local/bin/cx ] && echo created || echo none)"
' 2>&1)

it "exits 1 for a missing required dependency"
assert_contains "$_out" 'EXIT=1'

it "writes nothing when requirements are unmet"
assert_contains "$_out" 'SHIM=none'

summary
