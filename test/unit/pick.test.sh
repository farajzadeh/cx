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

# Everything below reads listings, and reading JSON means jq — which the
# bash:3.2 image `test/run.sh --bash32` uses does not carry. That run is
# asking about bash, not jq: skip rather than fail, as bar.test.sh does.
if ! cx_have jq; then
  describe "candidates"
  it "need jq"
  skip "jq unavailable"
  summary
  exit $?
fi

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

describe "options"

it "--query pre-seeds the filter, and a single match chooses itself"
answer q
assert_eq "$(printf '%s\n' "$ROWS" | cx_pick --query blog)" "web2:blog"

it "--query narrows but still asks when several match"
answer 2
assert_eq "$(printf '%s\n' "$ROWS" | cx_pick --query web1)" "web1:api/authfix"

it "--always-ask asks even for a single candidate"
answer 1
: >"$TMP/screen"
assert_eq "$(printf 'only:one\tonly:one\n' | cx_pick --always-ask)" "only:one"
assert_contains "$(cat "$TMP/screen")" "only:one" "...and showed the menu"

it "--always-ask can be cancelled on a single candidate"
answer q
rc=0
printf 'only:one\tonly:one\n' | cx_pick --always-ask >/dev/null || rc=$?
assert_eq "$rc" 130

it "--always-ask does not let a --query that leaves one row choose it"
answer q
rc=0
printf '%s\n' "$ROWS" | cx_pick --always-ask --query blog >/dev/null || rc=$?
assert_eq "$rc" 130

it "--always-ask still lets typed text choose"
answer blog
assert_eq "$(printf '%s\n' "$ROWS" | cx_pick --always-ask)" "web2:blog"

describe "session candidates"

# The agent's `sessions` verb, stubbed per host. Every call is logged, so a
# test can say which servers were asked. projects.sh first: it brings in
# remote.sh, whose real cx_agent would otherwise replace the stub the first
# time a picker sources it.
# shellcheck source=../../lib/projects.sh
. "$ROOT/lib/projects.sh"
cx_agent() {
  printf '%s %s\n' "$1" "$2" >>"$TMP/agent.log"
  case "$2" in
    sessions)
      [ -f "$TMP/sessions-$1.json" ] || return 1
      cat "$TMP/sessions-$1.json"
      ;;
    *) return 1 ;;
  esac
}
cat >"$TMP/sessions-web1.json" <<'EOF'
{"host":"web1","attach_detaches":false,"sessions":[
 {"project":"api","target":"api","attached":false},
 {"project":"api","label":"review","target":"api@review","attached":true},
 {"project":"api","worktree":"authfix","target":"api/authfix","attached":false},
 {"project":null,"target":null,"attached":false}]}
EOF
cx_state_write <<'EOF'
web1	api	idle
web1	api@review	blocked
web1	site@old	dead
EOF

it "lists every live session, labels included, with their state"
got=$(cx_pick_candidates session)
assert_eq "$got" "$(printf 'web1:api\tweb1:api\tsession\t●\tidle
web1:api@review\tweb1:api@review\tsession\t● attached\tblocked
web1:api/authfix\tweb1:api/authfix\tsession\t●\t')"

it "any is units then sessions, each target once"
got=$(cx_pick_candidates any | cut -f1 | tr '\n' ' ')
assert_eq "$got" "web1:api web1:api/authfix web1:site web1:api@review "

it "any keeps the unit's branch for a project's default session"
got=$(cx_pick_candidates any | head -1)
assert_eq "$got" "$(printf 'web1:api\tweb1:api\tmain\t●2\tidle')"

it "worktree offers worktrees only"
got=$(cx_pick_candidates worktree | cut -f1 | tr '\n' ' ')
assert_eq "$got" "web1:api/authfix "

it "finished offers sessions last seen dead, then every unit"
got=$(cx_pick_candidates finished | cut -f1 | tr '\n' ' ')
assert_eq "$got" "web1:site@old web1:api web1:api/authfix web1:site "

it "a host remembered as unreachable is not asked"
printf 'Host web2\n' >"$CX_SSHD_DIR/web2.conf"
cx_cache_mark_down web2
rm -f "$TMP/agent.log"
cx_pick_candidates session >/dev/null
assert_not_contains "$(cat "$TMP/agent.log")" "web2"
assert_contains "$(cat "$TMP/agent.log")" "web1 sessions" "...while the others are"

it "a host that fails is left out, not fatal"
cx_cache_clear_down web2
got=$(cx_pick_candidates session | cut -f1 | tr '\n' ' ')
assert_eq "$got" "web1:api web1:api@review web1:api/authfix "
rm -f "$CX_SSHD_DIR/web2.conf"

describe "the preview"

it "shows the unit from the cached listing"
rm -f "$TMP/agent.log"
got=$(cx_pick_preview web1:api/authfix)
assert_contains "$got" "branch     authfix"

it "shows the unit's sessions and their states"
got=$(cx_pick_preview web1:api@review)
assert_contains "$got" "web1:api@review"
assert_contains "$got" "blocked" "...with the state"
assert_contains "$got" "branch     main" "...and the project"

it "lists a project's worktrees"
assert_contains "$(cx_pick_preview web1:api)" "worktrees  authfix"

it "tolerates the delimiter fzf may leave on the field"
assert_contains "$(cx_pick_preview "$(printf 'web1:site\t')")" "branch     dev"

it "says so when nothing is cached for the host"
assert_contains "$(cx_pick_preview web9:x)" "nothing cached for web9"

it "never goes to the network"
assert_eq "$(cat "$TMP/agent.log" 2>/dev/null)" ""

it "explains the new-session row"
assert_contains "$(cx_pick_preview +new)" "new session"

it "the preview command runs this installation's cx on the value"
assert_contains "$(cx_pick_preview_cmd)" "$ROOT/bin/cx' find --preview {1}"

describe "cx_target_or_pick"

it "without a terminal: the old error, the caller's hints, exit 3"
rc=0
out=$(cx_target_or_pick unit open "usage: cx open <host>:<project>" 2>&1) || rc=$?
assert_eq "$rc" 3
assert_contains "$out" "no target given" "...saying no target was given"
assert_contains "$out" "usage: cx open <host>:<project>" "...with the caller's hint"

_cx_pick_tty() { return 0; }

it "at a terminal: offers KIND and prints the value"
answer site
assert_eq "$(cx_target_or_pick unit open 2>/dev/null)" "web1:site"

it "says what was chosen, on stderr"
answer site
assert_contains "$(cx_target_or_pick unit open 2>&1 >/dev/null)" "open web1:site"

it "a cancel is 130, and says so quietly"
answer q
rc=0
out=$(cx_target_or_pick unit open 2>&1) || rc=$?
assert_eq "$rc" 130
assert_contains "$out" "cancelled"

it "works under set -eu, as every command runs"
answer site
assert_eq "$(
  set -eu
  cx_target_or_pick unit open 2>/dev/null
)" "web1:site"

it "nothing to offer is 2, with what to do about it"
mv "$CX_CACHE_DIR/list/web1.json" "$TMP/list.bak"
rc=0
out=$(cx_target_or_pick unit open 2>&1) || rc=$?
assert_eq "$rc" 2
assert_contains "$out" "no projects to choose from"
mv "$TMP/list.bak" "$CX_CACHE_DIR/list/web1.json"

# The built-in menu opens its "terminal" afresh for each question, so each
# question reads the file from its first line. The keys below are chosen to
# mean the right thing to every question that reads them: "new" picks the
# new-session row from the first menu, matches nothing in the second (so
# "site" is read next), and is a valid label for the third.
it "--new offers a new session: a unit, then a label"
answer new site
assert_eq "$(cx_target_or_pick --new any open 2>/dev/null)" "web1:site@new"

it "--new refuses a label the target grammar would"
# The same trick: "+ new" still picks the new-session row, and as a label it
# is invalid — it has a space.
answer "+ new" site
rc=0
cx_target_or_pick --new any open >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 3

it "--always-ask reaches the menu"
answer q
rc=0
cx_target_or_pick --always-ask worktree stop >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 130

unset -f _cx_pick_tty

summary
