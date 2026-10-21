#!/usr/bin/env bash
# Unit tests for watching a session read-only: the agent's view verb and
# `cx open --view`, which cx web --terminal runs inside ttyd.
#
# What matters is what view will not do: create a session, or attach a
# client that can type or resize the window under whoever is working in it.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-view.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

# ===========================================================================
# The agent
# ===========================================================================
if [ "$HAVE_JQ" = 1 ]; then (
  export CX_DATA_DIR="$TMP/data" CX_CLAUDE_DIR="$TMP/claude"
  export CX_REGISTRY="$TMP/data/projects.json" CX_SESSIONS="$TMP/data/sessions.json"
  export CX_GOALS="$TMP/data/goals.json" CX_STATE_DIR="$TMP/data/state"
  export CX_AGENT_NO_MAIN=1
  mkdir -p "$CX_DATA_DIR" "$TMP/api"

  # shellcheck source=../../server/cx-agent
  . "$ROOT/server/cx-agent"
  set +eu

  cat >"$CX_REGISTRY" <<EOF
{"version":1,"root":"$TMP","projects":[{"name":"api","path":"$TMP/api"}]}
EOF

  # tmux, recorded. A program on PATH rather than a function, because view
  # execs it and exec does not run functions.
  export TMUX_V="tmux 3.4" TMP
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TMP/tmux.log"
case "$1" in
  -V) printf '%s\n' "$TMUX_V" ;;
  has-session) [ -e "$TMP/tmux.up" ] ;;
esac
EOF
  chmod +x "$TMP/bin/tmux"
  PATH="$TMP/bin:$PATH"
  view() {
    rm -f "$TMP/tmux.log"
    (cmd_view "$@") >/dev/null 2>"$TMP/err"
    VIEW_RC=$?
  }
  attach_line() { grep '^attach' "$TMP/tmux.log" 2>/dev/null; }

  describe "agent: view"
  it "refuses a session that is not running, with exit 2, and creates nothing"
  view api --session x
  assert_eq "$VIEW_RC" 2
  assert_not_contains "$(cat "$TMP/tmux.log")" "new-session"
  assert_eq "$(attach_line)" ""

  : >"$TMP/tmux.up"
  it "attaches read-only and without resizing the window, on tmux 3.2 or newer"
  view api --session x
  assert_eq "$(attach_line)" "attach -t =cx-api@x -f read-only,ignore-size"
  it "and read-only alone on an older tmux"
  TMUX_V="tmux 3.1c" view api --session x
  assert_eq "$(attach_line)" "attach -r -t =cx-api@x"
  it "never detaches anyone else"
  assert_not_contains "$(attach_line)" " -d"
  it "uses the exact-match target, never a prefix"
  view api
  assert_eq "$(attach_line)" "attach -t =cx-api -f read-only,ignore-size"
  it "refuses a label that is not one"
  view api --session 'a;b'
  assert_eq "$VIEW_RC" 3

  summary
) || FAILED_AGENT=1; else
  printf '  (agent half skipped: no jq)\n'
fi

# ===========================================================================
# The client
# ===========================================================================
export CX_HOME="$ROOT"
# shellcheck source=../../lib/compat.sh
. "$ROOT/lib/compat.sh"
# shellcheck source=../../lib/config.sh
. "$ROOT/lib/config.sh"
# shellcheck source=../../lib/ui.sh
. "$ROOT/lib/ui.sh"
# shellcheck source=../../lib/remote.sh
. "$ROOT/lib/remote.sh"
# shellcheck source=../../lib/cmd/open.sh
. "$ROOT/lib/cmd/open.sh"

AGENT_V=0.8.0
cx_target_resolve() {
  # shellcheck disable=SC2034  # read by _open_common
  CX_T_HOST=web1 CX_T_PROJECT=api CX_T_WORKTREE="" CX_T_SESSION=x
}
cx_agent() { [ "$2" = version ] && printf '%s\n' "$AGENT_V"; }
cx_ssh_opts() { printf '%s' "-o BatchMode=no"; }
# ssh is exec'd, so it has to be a program: one that prints what it got.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' >"$TMP/bin/ssh"
chmod +x "$TMP/bin/ssh"
PATH="$TMP/bin:$PATH"

describe "client: cx open --view"
it "asks the agent to view, with a terminal, every word quoted, and nothing else"
out=$( (_open_common continue --view web1:api@x) 2>/dev/null)
assert_eq "$(printf '%s\n' "$out" | tr '\n' ' ')" \
  "-t -o BatchMode=no web1 \$HOME/.local/bin/cx-agent 'view' 'api' '--session' 'x' "
for opt in -d --no-hooks --remote-control "--permission-mode plan"; do
  it "refuses $opt alongside it: a view starts nothing"
  # shellcheck disable=SC2086  # $opt is one or two words on purpose
  (_open_common continue --view $opt web1:api@x) >/dev/null 2>&1
  assert_eq "$?" 3
done
it "refuses an agent older than 0.8.0, which has no view"
AGENT_V=0.7.0
(_open_common continue --view web1:api@x) >/dev/null 2>&1
assert_eq "$?" 1

summary
rc=$?
[ -z "${FAILED_AGENT:-}" ] || exit 1
exit "$rc"
