#!/usr/bin/env bash
# Unit tests for two agent verbs about a session's lifecycle rather than its
# state: whether opening one has to throw out whoever else is attached, and
# forgetting one that has finished.
#
# Reached through CX_AGENT_NO_MAIN, with tmux replaced by stubs: which version
# is installed, and whether a session is running, are both facts these tests
# have to be able to choose.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-sessions.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export CX_DATA_DIR="$TMP/data" CX_CLAUDE_DIR="$TMP/claude"
export CX_REGISTRY="$TMP/data/projects.json" CX_SESSIONS="$TMP/data/sessions.json"
export CX_GOALS="$TMP/data/goals.json" CX_STATE_DIR="$TMP/data/state"
export CX_AGENT_NO_MAIN=1
mkdir -p "$CX_DATA_DIR" "$CX_STATE_DIR"

# shellcheck source=../../server/cx-agent
. "$ROOT/server/cx-agent"
set +eu

TMUX_VERSION="tmux 3.4"
tmux() {
  case "$1" in
    -V)
      [ -n "$TMUX_VERSION" ] || return 1
      printf '%s\n' "$TMUX_VERSION"
      ;;
    *) return 0 ;;
  esac
}
detaches() {
  TMUX_VERSION="$1"
  if _attach_must_detach; then printf yes; else printf no; fi
}

describe "_attach_must_detach — may a tab share a session with a terminal?"

it "shares on tmux 3.4, which sizes a window to its latest client"
assert_eq "$(detaches 'tmux 3.4')" no

it "shares from 3.1, where that became possible"
assert_eq "$(detaches 'tmux 3.1')" no

it "reads a lettered release like 3.3a"
assert_eq "$(detaches 'tmux 3.3a')" no

it "reads a development build"
assert_eq "$(detaches 'tmux next-3.5')" no

it "detaches on 3.0a, which sizes to the smallest client"
# A phantom client left by a dropped SSH connection would pin it small.
assert_eq "$(detaches 'tmux 3.0a')" yes

it "detaches on 2.9"
assert_eq "$(detaches 'tmux 2.9')" yes

it "keeps the safe behaviour for a version it cannot read"
assert_eq "$(detaches 'tmux master')" yes

it "keeps the safe behaviour when tmux cannot say at all"
assert_eq "$(detaches '')" yes

if ! have jq; then
  describe "cmd_sessions and cmd_forget"
  it "need jq"
  skip "jq unavailable"
  summary
  exit $?
fi

describe "cmd_sessions — tells the client"

printf '{"version":1,"root":"%s","projects":[{"name":"api","path":"%s/api"}]}\n' "$TMP" "$TMP" >"$CX_REGISTRY"
_tmux_rows() { printf 'cx-api\t1\t1700000000\t1\t1700000100\tclaude\n'; }

it "that opening a session will not detach anyone, on a modern tmux"
TMUX_VERSION="tmux 3.4"
assert_eq "$(cmd_sessions | jq -r .attach_detaches)" false

it "that it will, on an old one"
TMUX_VERSION="tmux 2.9"
assert_eq "$(cmd_sessions | jq -r .attach_detaches)" true

it "and still lists the sessions"
assert_eq "$(cmd_sessions | jq -r '.sessions[0].target')" api

describe "cmd_forget — drop a finished session"

cat >"$CX_SESSIONS" <<'EOF'
{"version":1,"sessions":{
  "api":        {"uuid":"u-api"},
  "api@old":    {"uuid":"u-old", "perm_mode":"plan"},
  "api@other":  {"uuid":"u-other"}}}
EOF
printf 'idle\t1700000000\tStop\t\n' >"$CX_STATE_DIR/u-old"
RUNNING=""
_tmux_has() { [ -n "$RUNNING" ] && [ "$1" = "$RUNNING" ]; }

# forget ARGS — cmd_forget in a subshell. It refuses through `die`, which
# exits, and run_rc calls its command in this shell: without the subshell the
# first refusal would end the whole test file before its summary.
forget() { (cmd_forget "$@") >/dev/null 2>&1; }

OUT=$(cmd_forget api --session old 2>/dev/null)
RC=$?

it "succeeds"
assert_eq "$RC" 0

it "says what it forgot"
assert_eq "$(jq -r '[.target, .forgotten, .uuid] | join(" ")' <<<"$OUT")" "api@old true u-old"

it "drops that session's pin"
assert_eq "$(jq -r '.sessions["api@old"]' "$CX_SESSIONS")" null

it "leaves the unit's default session alone"
assert_eq "$(jq -r '.sessions.api.uuid' "$CX_SESSIONS")" u-api

it "leaves the unit's other labelled sessions alone"
assert_eq "$(jq -r '.sessions["api@other"].uuid' "$CX_SESSIONS")" u-other

it "drops what its hooks last reported"
assert_fail test -e "$CX_STATE_DIR/u-old"

it "refuses a session that is running"
# Its pin is what the next cx open resumes; dropping it would start a second
# conversation on top of the live one.
RUNNING=cx-api@other
run_rc forget api --session other
assert_eq "$_T_RC" 4

it "and keeps its pin"
assert_eq "$(jq -r '.sessions["api@other"].uuid' "$CX_SESSIONS")" u-other
RUNNING=""

it "says there is nothing to forget for a session it never pinned"
run_rc forget api --session never
assert_eq "$_T_RC" 2

it "rejects a label that could not be a label"
run_rc forget api --session '../x'
assert_eq "$_T_RC" 3

summary
