#!/usr/bin/env bash
# Unit tests for `cx jump` — which tab a key press lands on.
#
# tmux is stubbed and the state cache is written by hand, because the whole
# command is a decision over those two: what is waiting, in what order, which
# of it has a tab, and where "next" is from the tab you are on.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

export CX_HOME="$ROOT"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-jump.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export CX_CACHE_DIR="$TMP/cache" CX_SSHD_DIR="$TMP/ssh.d"
export CX_CONFIG_FILE="$TMP/no-such-config"

# shellcheck source=../../lib/compat.sh
. "$ROOT/lib/compat.sh"
# shellcheck source=../../lib/config.sh
. "$ROOT/lib/config.sh"
# shellcheck source=../../lib/ui.sh
. "$ROOT/lib/ui.sh"
# shellcheck source=../../lib/cache.sh
. "$ROOT/lib/cache.sh"
cx_config_load
# shellcheck source=../../lib/cmd/jump.sh
. "$ROOT/lib/cmd/jump.sh"

cache() {
  mkdir -p "$CX_CACHE_DIR"
  printf '%b' "$1" >"$(cx_state_file)"
}

# Windows: session TAB window_id TAB @cx_target. HERE is the current tab's target.
WINDOWS=""
HERE=""
tmux() {
  printf '%s\n' "$*" >>"$TMP/tmux.log"
  case "$1" in
    list-windows) printf '%b' "$WINDOWS" ;;
    display-message)
      [ "${2:-}" = -p ] && printf '%s\n' "$HERE"
      ;;
  esac
  return 0
}
cx_have() { [ "$1" = tmux ] || command -v "$1" >/dev/null 2>&1; }

jump() {
  rm -f "$TMP/tmux.log"
  cmd_jump "$@" 2>&1
}
went() { grep '^select-window' "$TMP/tmux.log" 2>/dev/null | awk '{print $3}'; }

export TMUX=/tmp/tmux-test,1,0

cache 'web1:api\tidle\nweb1:api@review\tblocked\nweb1:web\tworking\nweb1:docs\tidle\n'
WINDOWS='cx\t@1\tweb1:api\ncx\t@2\tweb1:api@review\ncx\t@3\tweb1:web\ncx\t@4\tweb1:docs\nother\t@9\t\n'

describe "cx jump — where a key press lands"

it "goes to a blocked session before an idle one"
jump >/dev/null
assert_eq "$(went)" @2

it "switches the client to that tab's session"
assert_contains "$(cat "$TMP/tmux.log")" "switch-client -t cx"

it "goes to the next waiting session when pressed on the first"
HERE=web1:api@review
jump >/dev/null
assert_eq "$(went)" @1

it "keeps going down the list"
HERE=web1:api
jump >/dev/null
assert_eq "$(went)" @4

it "cycles back to the start from the last one"
HERE=web1:docs
jump >/dev/null
assert_eq "$(went)" @2

it "starts at the top from a tab that is not waiting"
HERE=web1:web
jump >/dev/null
assert_eq "$(went)" @2

it "never goes to a working session by default"
HERE=""
cache 'web1:web\tworking\n'
_out=$(jump)
assert_eq "$(went)" ""

it "says nothing is waiting, in tmux's own message line"
assert_contains "$(cat "$TMP/tmux.log")" "display-message cx: nothing is waiting"

it "prints nothing into the pane when run from a key binding"
assert_eq "$_out" ""

it "honours --states"
jump --states working >/dev/null
assert_eq "$(went)" @3

describe "cx jump — sessions it cannot reach"

it "skips a waiting session that has no tab"
cache 'web1:gone\tblocked\nweb1:docs\tidle\n'
jump >/dev/null
assert_eq "$(went)" @4

it "says how to open a tab when nothing waiting has one"
cache 'web1:gone\tblocked\n'
jump >/dev/null
assert_contains "$(cat "$TMP/tmux.log")" "cx open web1:gone"

it "says the state is stale rather than jumping on it"
cache 'web1:api\tblocked\n'
CX_STATE_TTL=0 jump >/dev/null
assert_contains "$(cat "$TMP/tmux.log")" "no recent session state"

it "does not jump anywhere on stale state"
assert_eq "$(went)" ""

describe "cx jump — outside tmux"

it "prints the session instead of switching"
cache 'web1:api@review\tblocked\n'
_out=$(TMUX='' cmd_jump 2>&1)
assert_contains "$_out" "web1:api@review"

it "and says which tmux session holds its tab"
assert_contains "$_out" "tmux attach -t cx"

describe "cx jump — arguments"

it "rejects a target"
assert_exit 3 cmd_jump web1:api

it "rejects an unknown state"
assert_exit 3 cmd_jump --states sideways

describe "cx bar --setup binds it"

# shellcheck source=../../lib/cmd/bar.sh
. "$ROOT/lib/cmd/bar.sh"

it "to prefix + j, without blocking tmux while it runs"
assert_contains "$(cmd_bar --setup)" 'bind-key j run-shell -b'

summary
