#!/usr/bin/env bash
# Unit tests for choosing a target instead of typing one: every command that
# picks when its target is left out, and `cx find` / `cx pick`.
#
# What is under test is the wiring, not the picker (pick.test.sh has that):
# does each command offer the right KIND of thing, pass the chosen value on
# as if it had been typed, and still fail exactly as before when nobody is at
# a terminal. So resolution is stubbed to record the target and stop there —
# nothing past that point changed, and nothing past it needs a server.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

export CX_HOME="$ROOT"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-find.XXXXXX")
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

for c in find; do
  # shellcheck disable=SC1090
  . "$ROOT/lib/cmd/$c.sh"
done
# Before the stubs below: projects.sh brings in remote.sh, whose real
# cx_agent would otherwise replace the stub when a picker first sources it.
# shellcheck source=../../lib/projects.sh
. "$ROOT/lib/projects.sh"

export CX_PICKER=builtin CX_PICK_TTY_OUT="$TMP/screen" CX_FORCE_STALE=1

# answer LINES... — what the human will type, one line each.
answer() {
  printf '%s\n' "$@" >"$TMP/keys"
  export CX_PICK_TTY_IN="$TMP/keys"
  : >"$TMP/screen"
}

# One server, cached: two projects, one worktree.
mkdir -p "$CX_SSHD_DIR" "$CX_CACHE_DIR/list"
printf 'Host web1\n' >"$CX_SSHD_DIR/web1.conf"
cat >"$CX_CACHE_DIR/list/web1.json" <<'EOF'
{"host":"web1","ok":true,"projects":[
 {"name":"api","branch":"main","tmux_live":true,"tmux_count":2,
  "worktrees":[{"name":"authfix","branch":"authfix","tmux_live":false}]},
 {"name":"site","branch":"dev","tmux_live":false}]}
EOF
cx_state_write <<'EOF'
web1	api	idle
web1	api@review	blocked
web1	site@old	dead
EOF

# Live sessions, as the agent's `sessions` verb reports them.
cat >"$TMP/sessions.json" <<'EOF'
{"host":"web1","sessions":[
 {"project":"api","target":"api","attached":false},
 {"project":"api","label":"review","target":"api@review","attached":false}]}
EOF
cx_agent() {
  case "$2" in
    sessions) cat "$TMP/sessions.json" ;;
    *) return 1 ;;
  esac
}

# Resolution records the target and stops: exit 42 is "picked, and handed on".
cx_target_resolve() {
  printf '%s\n' "$1" >"$TMP/resolved"
  return 42
}
# cx code looks for an editor before anything else.
cx_have() { [ "$1" = code ] || command -v "$1" >/dev/null 2>&1; }

# run CMD... — run under set -eu, as bin/cx does. Sets RC and RESOLVED.
run() {
  rm -f "$TMP/resolved"
  RC=0
  (
    set -eu
    "$@"
  ) >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  RESOLVED=$(cat "$TMP/resolved" 2>/dev/null || true)
}

_cx_pick_tty() { return 0; }

describe "cx find"

# The actions are the ordinary commands; record how each was called.
for c in open shell code peek stop nudge; do
  eval "cmd_$c() { printf '%s %s\n' $c \"\$*\" >\"\$TMP/ran\"; }"
done
load_cmd() { command -v "cmd_$1" >/dev/null 2>&1; }
ran() { cat "$TMP/ran" 2>/dev/null || true; }

it "--print writes the chosen target, and only that, to stdout"
answer site
run cmd_find --print
assert_eq "$RC" 0
assert_eq "$(cat "$TMP/out")" "web1:site"

it "a query starts the filter, and a unique match needs no question"
: >"$TMP/keys"
run cmd_find --print review
assert_eq "$(cat "$TMP/out")" "web1:api@review"

it "several words make one query"
: >"$TMP/keys"
run cmd_find --print api auth
assert_eq "$(cat "$TMP/out")" "web1:api/authfix"

it "cx pick is the same command"
: >"$TMP/keys"
run cmd_pick -p site
assert_eq "$(cat "$TMP/out")" "web1:site"

it "then offers what to do, and runs that command"
rm -f "$TMP/ran"
answer shell
run cmd_find site
assert_eq "$(ran)" "shell web1:site"

it "code opens the unit, not the session"
rm -f "$TMP/ran"
answer code
run cmd_find review
assert_eq "$(ran)" "code web1:api"

it "peek, open and stop take the target as chosen"
# Typed as the human would: "open" also matches the new-session row, whose
# description mentions cx open, so that one is chosen by its own words.
for a in peek:peek open:attach stop:stop; do
  rm -f "$TMP/ran"
  answer "${a#*:}"
  run cmd_find review
  assert_eq "$(ran)" "${a%%:*} web1:api@review" "${a%%:*}"
done

it "nudge asks for the text, then sends it"
rm -f "$TMP/ran"
# The action menu and the text prompt both read the first line.
answer nudge
run cmd_find review
assert_eq "$(ran)" "nudge web1:api@review nudge"

it "a new session asks for a label and opens unit@label"
rm -f "$TMP/ran"
answer new
run cmd_find review
assert_eq "$(ran)" "open web1:api@new"

it "print prints"
answer print
run cmd_find site
assert_eq "$(cat "$TMP/out")" "web1:site"

it "the action menu is always asked, and can be cancelled"
rm -f "$TMP/ran"
answer q
run cmd_find site
assert_eq "$RC:$(ran)" "130:"

it "--preview answers from the cache, without a terminal"
unset -f _cx_pick_tty
run cmd_find --preview web1:api
assert_eq "$RC" 0
assert_contains "$(cat "$TMP/out")" "branch     main"

it "needs a terminal otherwise"
run cmd_find --print
assert_eq "$RC" 3

summary
