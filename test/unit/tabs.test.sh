#!/usr/bin/env bash
# Unit tests for `cx tabs` — the one command that drives tmux on this machine.
#
# tmux and the agent are both stubbed. What is being pinned is the arithmetic
# of the thing: which sessions get a window, which are skipped, which are
# flagged as about to be taken from another terminal, and that --dry-run opens
# nothing at all. Whether tmux then draws the window is tmux's business.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

export CX_HOME="$ROOT"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-tabs.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export CX_CACHE_DIR="$TMP/cache" CX_SSHD_DIR="$TMP/ssh.d"
export CX_CONFIG_FILE="$TMP/no-such-config"
mkdir -p "$CX_SSHD_DIR"

# shellcheck source=../../lib/compat.sh
. "$ROOT/lib/compat.sh"
# shellcheck source=../../lib/config.sh
. "$ROOT/lib/config.sh"
# shellcheck source=../../lib/ui.sh
. "$ROOT/lib/ui.sh"
# shellcheck source=../../lib/cache.sh
. "$ROOT/lib/cache.sh"
cx_config_load
# shellcheck source=../../lib/cmd/tabs.sh
. "$ROOT/lib/cmd/tabs.sh"

if ! cx_have jq; then
  describe "cx tabs"
  it "needs jq"
  skip "jq unavailable"
  summary
  exit $?
fi

printf 'Host web1\n' >"$CX_SSHD_DIR/web1.conf"

# The agent's `sessions` answer. Stubbed after tabs.sh, which sources
# lib/remote.sh and would define the real one over the top.
SESSIONS='{"sessions":[
  {"target":"api","attached":false},
  {"target":"api@review","attached":true},
  {"target":"api/authfix","attached":false}]}'
cx_agent() { printf '%s' "$SESSIONS"; }

# Every tmux call is recorded. WINDOWS is what list-windows reports back, so a
# test can say "this session already has these tabs".
WINDOWS=""
HAVE_SESSION=1
tmux() {
  printf '%s\n' "$*" >>"$TMP/tmux.log"
  case "$1 ${2:-}" in
    "has-session -t") return "$HAVE_SESSION" ;;
    "list-windows -t") printf '%s\n' "$WINDOWS" ;;
    "new-window -P") printf '@9\n' ;;
  esac
  return 0
}
cx_have() { [ "$1" = tmux ] || command -v "$1" >/dev/null 2>&1; }
tput() { return 1; } # no terminal in a test; exercises the size fallback

run_tabs() {
  rm -f "$TMP/tmux.log"
  cmd_tabs "$@" 2>&1
}
log() { cat "$TMP/tmux.log" 2>/dev/null || true; }

# ---------------------------------------------------------------------------

describe "cx tabs — which sessions get a window"

it "lists every live session"
_out=$(run_tabs -n)
assert_contains "$_out" "web1:api/authfix"

it "flags one that another terminal is already attached to"
# cx open attaches with `tmux attach -d`, so the tab takes the session. Saying
# so before it happens is the whole difference between a tool and a surprise.
assert_contains "$(run_tabs -n)" "open elsewhere"

it "marks only the attached one"
assert_eq "$(run_tabs -n | grep -c 'open elsewhere')" 1

it "opens nothing at all on a dry run"
run_tabs -n >/dev/null
assert_not_contains "$(log)" "new-session"

it "says so, rather than leaving you wondering"
assert_contains "$(run_tabs -n)" "nothing was changed"

describe "cx tabs — building the session"

it "creates the session for the first window"
run_tabs --no-attach >/dev/null
assert_contains "$(log)" "new-session -d -s cx"

it "sizes it to something a terminal would use, not tmux's 80x24"
# A detached session is 80x24, and every tab's cx open would then resize the
# session it attaches to down to that. This is the fallback path: no terminal.
assert_contains "$(log)" "-x 200 -y 50"

it "adds the rest as windows"
HAVE_SESSION=0
run_tabs --no-attach >/dev/null
assert_eq "$(log | grep -c 'new-window')" 3

it "tags every window it opens"
assert_eq "$(log | grep -c 'set-option -w -t @9 @cx_target')" 3

it "addresses the tag by window id, never the active window"
assert_not_contains "$(log)" "set-option -w @cx_target"

describe "cx tabs — running it again"

HAVE_SESSION=0
WINDOWS="web1:api
web1:api@review"

it "skips sessions that already have a tab"
run_tabs --no-attach >/dev/null
assert_eq "$(log | grep -c 'new-window')" 1

it "opens the one that does not"
assert_contains "$(log)" "web1:api/authfix"

it "says what it skipped"
assert_contains "$(run_tabs --no-attach)" "already there"

it "does nothing when every session already has one"
WINDOWS="web1:api
web1:api@review
web1:api/authfix"
_out=$(run_tabs --no-attach)
assert_contains "$_out" "Nothing new"

it "and really does nothing"
assert_not_contains "$(log)" "new-window"

describe "cx tabs — the edges"

it "says so when no session is live"
SESSIONS='{"sessions":[]}'
assert_contains "$(run_tabs -n)" "No live sessions"

it "reports a server that did not answer rather than dropping it"
cx_agent() { return 255; }
assert_contains "$(run_tabs -n)" "unreachable"

it "takes no target, and points at cx open instead"
assert_exit 3 cmd_tabs web1:api

it "rejects an unknown option"
assert_exit 3 cmd_tabs --follow

it "needs a name for --session"
assert_exit 3 cmd_tabs --session

summary
