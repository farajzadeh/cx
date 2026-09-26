#!/usr/bin/env bash
# Unit tests for lib/pick.sh — the interactive picker.
#
# fzf is never used here (CX_PICKER=builtin): what is under test is the
# contract every command relies on — the value comes back untouched, a cancel
# is 130, nothing to choose from is 2, and there is no prompt at all when no
# human is there to answer. The built-in menu reads its "terminal" from a file.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

export CX_HOME="$ROOT"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-pick.XXXXXX")
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
# shellcheck source=../../lib/pick.sh
. "$ROOT/lib/pick.sh"

export CX_PICKER=builtin CX_PICK_TTY_OUT="$TMP/screen"

# answer LINES... — what the human will type, one line each.
answer() {
  printf '%s\n' "$@" >"$TMP/keys"
  export CX_PICK_TTY_IN="$TMP/keys"
  : >"$TMP/screen"
}

ROWS=$(printf 'web1:api\tweb1:api\tmain\t●\nweb1:api/authfix\tweb1:api/authfix\tauthfix\t\nweb2:blog\tweb2:blog\tmain\t\n')

describe "alignment"

it "keeps the value column untouched and pads the display"
got=$(printf 'v1\ta\tbb\nvalue two\tccc\td\n' | _cx_pick_align)
assert_eq "$got" "$(printf 'v1\ta    bb\nvalue two\tccc  d')"

describe "the built-in menu"

it "returns the value of the numbered row"
answer 2
assert_eq "$(printf '%s\n' "$ROWS" | cx_pick)" "web1:api/authfix"

it "narrows by text, and a single match chooses itself"
answer blog
assert_eq "$(printf '%s\n' "$ROWS" | cx_pick)" "web2:blog"

it "matches every word, case-insensitively"
answer "API AUTH"
assert_eq "$(printf '%s\n' "$ROWS" | cx_pick)" "web1:api/authfix"

it "numbers rows within the filtered list"
answer web1 2
assert_eq "$(printf '%s\n' "$ROWS" | cx_pick)" "web1:api/authfix"

it "an empty line clears the filter"
answer web1 "" 3
assert_eq "$(printf '%s\n' "$ROWS" | cx_pick)" "web2:blog"

it "survives an out-of-range number and asks again"
answer 9 1
assert_eq "$(printf '%s\n' "$ROWS" | cx_pick)" "web1:api"

it "says so when a filter matches nothing"
answer zzz q
printf '%s\n' "$ROWS" | cx_pick >/dev/null
assert_contains "$(cat "$TMP/screen")" 'no match for "zzz"'

it "q cancels with 130"
answer q
rc=0
printf '%s\n' "$ROWS" | cx_pick >/dev/null || rc=$?
assert_eq "$rc" 130

it "end of input cancels with 130"
answer
: >"$TMP/keys"
rc=0
printf '%s\n' "$ROWS" | cx_pick >/dev/null || rc=$?
assert_eq "$rc" 130

it "a single candidate needs no question"
printf 'x\n' >"$TMP/keys"
assert_eq "$(printf 'only:one\tonly:one\n' | cx_pick)" "only:one"

it "nothing to choose from is not-found, 2"
rc=0
printf '' | cx_pick >/dev/null || rc=$?
assert_eq "$rc" 2

it "the menu goes to the terminal, never to stdout"
answer 1
out=$(printf '%s\n' "$ROWS" | cx_pick)
assert_eq "$out" "web1:api"
assert_contains "$(cat "$TMP/screen")" "web2:blog"

it "keeps stderr working after the menu has run"
answer 1
printf '%s\n' "$ROWS" | cx_pick >/dev/null
assert_eq "$({ printf 'still here' >&2; } 2>&1)" "still here"

describe "when to ask at all"

it "never asks without a terminal"
rc=0
cx_pick_ok </dev/null 2>/dev/null || rc=$?
assert_eq "$rc" 1

it "asks when there is a terminal and nothing says not to"
_cx_pick_tty() { return 0; }
rc=0
cx_pick_ok || rc=$?
assert_eq "$rc" 0

for v in CX_JSON=1 CX_ASSUME_YES=1 CX_PICKER=none; do
  rc=0
  (
    export "${v?}"
    cx_pick_ok
  ) || rc=$?
  assert_eq "$rc" 1 "never asks under $v"
done
unset -f _cx_pick_tty

describe "candidates"

# A cached listing, as the agent's `list` returns it.
mkdir -p "$CX_SSHD_DIR" "$CX_CACHE_DIR/list"
printf 'Host web1\n' >"$CX_SSHD_DIR/web1.conf"
cat >"$CX_CACHE_DIR/list/web1.json" <<'EOF'
{"host":"web1","ok":true,"projects":[
 {"name":"api","branch":"main","tmux_live":true,"tmux_count":2,
  "worktrees":[{"name":"authfix","branch":"authfix","tmux_live":false}]},
 {"name":"site","branch":"dev","tmux_live":false}]}
EOF
export CX_FORCE_STALE=1

it "project lists projects only"
got=$(cx_pick_candidates project | cut -f1 | tr '\n' ' ')
assert_eq "$got" "web1:api web1:site "

it "unit adds worktrees under their project"
got=$(cx_pick_candidates unit | cut -f1 | tr '\n' ' ')
assert_eq "$got" "web1:api web1:api/authfix web1:site "

it "shows branch and liveness"
got=$(cx_pick_candidates unit | head -1)
assert_eq "$got" "$(printf 'web1:api\tweb1:api\tmain\t●2')"

summary
