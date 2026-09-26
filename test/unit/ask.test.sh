#!/usr/bin/env bash
# Unit tests for cx_ask_line and cx_ask_yn in lib/pick.sh — the questions
# asked when a command is run bare at a terminal.
#
# The "terminal" is a file, as in pick.test.sh. That makes one property worth
# pinning above the others: successive questions read successive lines, which
# a plain file only does if the input stays open between them.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

export CX_HOME="$ROOT"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-ask.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export CX_CACHE_DIR="$TMP/cache" CX_SSHD_DIR="$TMP/ssh.d"
export CX_CONFIG_FILE="$TMP/no-such-config"

# shellcheck source=../../lib/compat.sh
. "$ROOT/lib/compat.sh"
# shellcheck source=../../lib/config.sh
. "$ROOT/lib/config.sh"
# shellcheck source=../../lib/ui.sh
. "$ROOT/lib/ui.sh"
cx_config_load
# shellcheck source=../../lib/pick.sh
. "$ROOT/lib/pick.sh"

export CX_PICK_TTY_OUT="$TMP/screen"

# fresh [ANSWERS...] — what the human will type, one line each.
fresh() {
  : >"$TMP/screen"
  printf '%s\n' "$@" >"$TMP/keys"
  export CX_PICK_TTY_IN="$TMP/keys"
  cx_ask_reset
}

describe "cx_ask_line and cx_ask_yn"

it "reads one line"
fresh "hello"
cx_ask_line "name"
assert_eq "$CX_ASK_REPLY" "hello"

it "shows the prompt on the terminal, not stdout"
assert_contains "$(cat "$TMP/screen")" "name"

it "successive questions read successive lines"
fresh "one" "two"
cx_ask_line "a"
a="$CX_ASK_REPLY"
cx_ask_line "b"
assert_eq "$a/$CX_ASK_REPLY" "one/two"

it "an empty answer takes the default"
fresh ""
cx_ask_line "branch" "authfix"
assert_eq "$CX_ASK_REPLY" "authfix"

it "shows the default"
assert_contains "$(cat "$TMP/screen")" "[authfix]"

it "trims surrounding blanks"
fresh "  api  "
cx_ask_line "name"
assert_eq "$CX_ASK_REPLY" "api"

it "a last line with no newline still counts"
fresh
printf 'tail' >"$TMP/keys"
cx_ask_line "name"
assert_eq "$CX_ASK_REPLY" "tail"

it "end of input is a cancel, 130"
fresh
: >"$TMP/keys"
rc=0
cx_ask_line "name" || rc=$?
assert_eq "$rc" 130

it "no terminal to read at all is a cancel too"
fresh
export CX_PICK_TTY_IN="$TMP/no-such-tty"
rc=0
cx_ask_line "name" || rc=$?
assert_eq "$rc" 130

it "yes/no: an empty answer is the default"
fresh ""
rc=0
cx_ask_yn "open?" y || rc=$?
assert_eq "$rc" 0

it "yes/no: the default shows as the capital"
assert_contains "$(cat "$TMP/screen")" "[Y/n]"

it "yes/no: an empty answer to a default of no is no"
fresh ""
rc=0
cx_ask_yn "open?" n || rc=$?
assert_eq "$rc" 1

it "yes/no: n is no"
fresh "n"
rc=0
cx_ask_yn "open?" y || rc=$?
assert_eq "$rc" 1

it "yes/no: asks again rather than guessing"
fresh "maybe" "yes"
rc=0
cx_ask_yn "open?" n || rc=$?
assert_eq "$rc" 0
assert_contains "$(cat "$TMP/screen")" "please answer y or n" "and says why"

it "yes/no: end of input is 130"
fresh
: >"$TMP/keys"
rc=0
cx_ask_yn "open?" y || rc=$?
assert_eq "$rc" 130

it "keeps stderr working after asking"
fresh "x"
cx_ask_line "name"
assert_eq "$({ printf 'still here' >&2; } 2>&1)" "still here"

summary
