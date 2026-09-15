#!/usr/bin/env bash
# Unit tests for the one thing `cx open` does to the machine it runs on:
# tagging the local tmux window with the session it is about to attach.
#
# tmux is stubbed rather than run. What matters here is the decision — when to
# tag, when to rename, when to keep hands off — not tmux's own behaviour, and
# a stub is the only way to assert "it did nothing" at all.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

export CX_HOME="$ROOT"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-open.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export CX_CONFIG_FILE="$TMP/no-such-config"
export CX_SSHD_DIR="$TMP/ssh.d"
export CX_CACHE_DIR="$TMP/cache"

# shellcheck source=../../lib/compat.sh
. "$ROOT/lib/compat.sh"
# shellcheck source=../../lib/config.sh
. "$ROOT/lib/config.sh"
# shellcheck source=../../lib/ui.sh
. "$ROOT/lib/ui.sh"
# shellcheck source=../../lib/cache.sh
. "$ROOT/lib/cache.sh"
cx_config_load
# shellcheck source=../../lib/cmd/open.sh
. "$ROOT/lib/cmd/open.sh"

# Every tmux invocation is recorded instead of run.
tmux() {
  printf '%s\n' "$*" >>"$TMP/tmux.log"
}
# cx_have must agree that the stub exists, or the guard skips everything.
cx_have() { [ "$1" = tmux ] || command -v "$1" >/dev/null 2>&1; }

# The target cx open has already resolved. Read by cx_target_str, which is
# what _open_tag_window records.
# shellcheck disable=SC2034
CX_T_HOST=web1
# shellcheck disable=SC2034
CX_T_PROJECT=api
# shellcheck disable=SC2034
CX_T_WORKTREE=authfix
# shellcheck disable=SC2034
CX_T_SESSION=tests

# tag [WHERE] [TAG] [TITLE] — run _open_tag_window in a controlled world and
# print every tmux command it issued. WHERE is "none" for outside tmux.
tag() {
  local where="${1:-in}" want_tag="${2:-1}" want_title="${3:-0}"
  rm -f "$TMP/tmux.log"
  (
    if [ "$where" = none ]; then
      unset TMUX
    else
      TMUX=/tmp/tmux-1000/default,123,0
      export TMUX
    fi
    TMUX_PANE="%7"
    export TMUX_PANE
    CX_TMUX_TAG="$want_tag" CX_TMUX_TITLE="$want_title" _open_tag_window
  )
  cat "$TMP/tmux.log" 2>/dev/null || true
}

describe "_open_tag_window — what cx open does to your own tmux"

it "records the full target, so the tab can be looked up later"
assert_contains "$(tag in 1 0)" "@cx_target web1:api/authfix@tests"

it "tags the window this pane is in, not whichever one is active"
# "Current window" is the session's active window. For a tab opening in the
# background — or nine opening at once into a detached session — that is a
# different window, and eight of the nine silently got no tag at all.
assert_contains "$(tag in 1 0)" "set-option -w -t %7 @cx_target"

it "renames that same window rather than the active one"
assert_contains "$(tag in 1 1)" "rename-window -t %7"

it "does not rename the window by default"
# tmux turns off automatic-rename for any window given an explicit name, which
# is a lasting change to how someone's own tmux behaves. Setting a user option
# is invisible; renaming is not, so renaming is the part you opt into.
assert_not_contains "$(tag in 1 0)" "rename-window"

it "renames it with CX_TMUX_TITLE=1"
assert_contains "$(tag in 1 1)" "api/authfix@tests"

it "renames it to the target without the host, which is what fits in a tab"
assert_not_contains "$(tag in 1 1)" "rename-window web1:"

it "does nothing at all outside tmux"
# No $TMUX means no window to tag. Running cx open from a plain terminal must
# not start poking at whatever tmux server happens to be on the machine.
assert_eq "$(tag none)" ""

it "does nothing when CX_TMUX_TAG=0"
assert_eq "$(tag in 0 0)" ""

it "survives tmux failing, because a tab title is never worth an exit code"
tmux() { return 1; }
run_rc _open_tag_window
assert_eq "$_T_RC" 0

describe "_open_bar_args — what cx open tells the agent about the server's bar"

# bar_args AGENT_VERSION CX_SERVER_BAR CX_BAR_ICONS — the flags, space-joined.
bar_args() {
  (
    CX_SERVER_BAR="$2" CX_BAR_ICONS="$3"
    export CX_SERVER_BAR CX_BAR_ICONS
    _open_bar_args "$1"
    printf '%s' "${_OPEN_BAR_ARGS[*]+${_OPEN_BAR_ARGS[*]}}"
  )
}

it "tells a new agent nothing by default, since a bar is its default"
assert_eq "$(bar_args 0.5.0 1 unicode)" ""

it "asks for Nerd Font icons when the tabs use them"
assert_eq "$(bar_args 0.5.0 1 nerd)" "--bar nerd"

it "turns it off with CX_SERVER_BAR=0"
assert_eq "$(bar_args 0.5.0 0 unicode)" "--bar off"

it "and off wins over the icon set"
assert_eq "$(bar_args 0.6.1 0 nerd)" "--bar off"

it "sends an older agent nothing, so it opens exactly as it did"
assert_eq "$(bar_args 0.4.0 0 nerd)" ""

it "and nothing when the version is not known"
assert_eq "$(bar_args "" 0 nerd)" ""

summary
