#!/usr/bin/env bash
# Unit tests for the target grammar in lib/target.sh.
#
#   [host:]project[/worktree][@session]
#
# Only cx_target_split and the string helpers are exercised here: they are
# pure, so they can be tested without a server. cx_target_resolve needs the
# network and is covered by test/integration/.
#
# lib/target.sh sources hosts.sh and projects.sh at load time, which in turn
# want config and a cache. Rather than stub all of that, this file defines
# CX_HOME and lets the real sourcing happen against a scratch HOME — nothing
# below actually reaches the filesystem or the network.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

export CX_HOME="$ROOT"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-target.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
export CX_SSHD_DIR="$TMP/ssh.d"
export CX_CACHE_DIR="$TMP/cache"

# shellcheck source=../../lib/compat.sh
. "$ROOT/lib/compat.sh"
# shellcheck source=../../lib/ui.sh
. "$ROOT/lib/ui.sh"
# shellcheck source=../../lib/cache.sh
. "$ROOT/lib/cache.sh"
# shellcheck source=../../lib/target.sh
. "$ROOT/lib/target.sh"

# The error helpers write to stderr; silence them so a deliberately invalid
# target does not look like a test failure.
err() { :; }
hint() { :; }

# split TARGET — parse and report the four components as one comparable string.
split() {
  CX_DEFAULT_HOST="" cx_target_split "$1" >/dev/null 2>&1 || return $?
  printf 'host=%s project=%s wt=%s session=%s' \
    "$CX_T_HOST" "$CX_T_PROJECT" "$CX_T_WORKTREE" "$CX_T_SESSION"
}

# ---------------------------------------------------------------------------

describe "cx_target_split — the forms that already existed"

it "splits host:project"
assert_eq "$(split web1:api)" 'host=web1 project=api wt= session='

it "leaves a bare project's host empty when CX_DEFAULT_HOST is unset"
assert_eq "$(split api)" 'host= project=api wt= session='

it "keeps dots, underscores and hyphens in a project name"
assert_eq "$(split 'web1:my.app_v2-x')" 'host=web1 project=my.app_v2-x wt= session='

describe "cx_target_split — worktrees"

it "splits host:project/worktree"
assert_eq "$(split web1:api/authfix)" 'host=web1 project=api wt=authfix session='

it "splits a bare project/worktree"
assert_eq "$(split api/authfix)" 'host= project=api wt=authfix session='

describe "cx_target_split — sessions"

it "splits host:project@label"
assert_eq "$(split web1:api@review)" 'host=web1 project=api wt= session=review'

it "splits a bare project@label"
assert_eq "$(split api@review)" 'host= project=api wt= session=review'

describe "cx_target_split — both at once"

it "splits host:project/worktree@label"
assert_eq "$(split web1:api/authfix@tests)" \
  'host=web1 project=api wt=authfix session=tests'

# The session label is peeled off BEFORE the worktree, so a '/' that appears
# after the '@' cannot be mistaken for a worktree separator.
it "does not treat a slash inside a label as a worktree separator"
assert_exit 3 split 'web1:api@bad/label'

describe "cx_target_split — rejections"

it "rejects an empty project"
assert_exit 3 split 'web1:'

it "rejects an empty session label"
assert_exit 3 split 'web1:api@'

it "rejects an empty worktree name"
assert_exit 3 split 'web1:api/'

it "rejects a dot in a session label (tmux rewrites it to an underscore)"
assert_exit 3 split 'web1:api@my.label'

it "rejects a dot in a worktree name"
assert_exit 3 split 'web1:api/my.wt'

it "rejects a worktree name starting with a hyphen"
assert_exit 3 split 'web1:api/-wt'

it "rejects a space in a session label"
assert_exit 3 split 'web1:api@two words'

describe "cx_target_str / cx_target_unit_str"

it "reassembles a plain target"
cx_target_split web1:api >/dev/null
assert_eq "$(cx_target_str)" 'web1:api'

it "reassembles a worktree target"
cx_target_split web1:api/authfix >/dev/null
assert_eq "$(cx_target_str)" 'web1:api/authfix'

it "reassembles a session target"
cx_target_split web1:api@review >/dev/null
assert_eq "$(cx_target_str)" 'web1:api@review'

it "reassembles both, in the order the grammar defines"
cx_target_split web1:api/authfix@tests >/dev/null
assert_eq "$(cx_target_str)" 'web1:api/authfix@tests'

it "drops the host in the unit form"
cx_target_split web1:api/authfix@tests >/dev/null
assert_eq "$(cx_target_unit_str)" 'api/authfix@tests'

# Round-tripping matters because cx prints targets back to the user as the
# thing to type next ("start working: cx open web1:api/authfix").
it "round-trips every form through split and str"
_rt_fail=""
for _t in web1:api web1:api@review web1:api/wt web1:api/wt@lbl; do
  cx_target_split "$_t" >/dev/null
  [ "$(cx_target_str)" = "$_t" ] || _rt_fail="$_rt_fail $_t"
done
assert_eq "$_rt_fail" ''

describe "cx_target_split resets state between calls"

# A stale CX_T_WORKTREE would silently send --worktree on the next command,
# opening the wrong directory.
it "clears the worktree when the next target has none"
cx_target_split web1:api/authfix >/dev/null
cx_target_split web1:api >/dev/null
assert_eq "$CX_T_WORKTREE" ''

it "clears the session label when the next target has none"
cx_target_split web1:api@review >/dev/null
cx_target_split web1:api >/dev/null
assert_eq "$CX_T_SESSION" ''

describe "cx_target_args — what gets sent to the agent"

it "sends nothing extra for a plain project"
cx_target_split web1:api >/dev/null
cx_target_args
assert_eq "${#CX_T_ARGS[@]}" '0'

it "sends only --worktree for a worktree target"
cx_target_split web1:api/authfix >/dev/null
cx_target_args
assert_eq "${CX_T_ARGS[*]+"${CX_T_ARGS[*]}"}" '--worktree authfix'

it "sends only --session for a labelled target"
cx_target_split web1:api@review >/dev/null
cx_target_args
assert_eq "${CX_T_ARGS[*]+"${CX_T_ARGS[*]}"}" '--session review'

it "sends both, worktree first"
cx_target_split web1:api/authfix@tests >/dev/null
cx_target_args
assert_eq "${CX_T_ARGS[*]+"${CX_T_ARGS[*]}"}" '--worktree authfix --session tests'

describe "cx_target_needs_units — the agent-version gate"

it "is false for a plain project, so old agents keep working"
cx_target_split web1:api >/dev/null
assert_fail cx_target_needs_units

it "is true for a worktree"
cx_target_split web1:api/authfix >/dev/null
assert_ok cx_target_needs_units

it "is true for a session label"
cx_target_split web1:api@review >/dev/null
assert_ok cx_target_needs_units

describe "cx_agent_supports — which agents are new enough"
#
# Every case passes the version explicitly. That is not only what keeps this
# test pure: it is the intended calling convention, because each caller has
# already run `version` or `doctor` for its own reasons and a second round
# trip per command is what turns a driver polling six sessions into six
# sequential SSH connections.

it "accepts an agent newer than the minimum"
assert_ok cx_agent_supports web1 "worktrees" 0.2.0 0.3.0

it "accepts an agent at exactly the minimum"
assert_ok cx_agent_supports web1 "goals" 0.3.0 0.3.0

it "rejects an agent below the minimum"
assert_fail cx_agent_supports web1 "goals" 0.3.0 0.2.0

it "accepts when the agent is absent, so the caller reports that instead"
assert_ok cx_agent_supports web1 "goals" 0.3.0 ""

it "still gates worktrees at 0.2.0"
assert_ok cx_agent_units_ok web1 0.2.0

it "still refuses worktrees on a 0.1.0 agent"
assert_fail cx_agent_units_ok web1 0.1.0

it "gates observing and steering at 0.3.0"
assert_ok cx_agent_observe_ok web1 0.3.0

it "refuses observing on the agent that shipped worktrees"
assert_fail cx_agent_observe_ok web1 0.2.0

it "gates goals at 0.3.0"
assert_ok cx_agent_goals_ok web1 0.3.0

it "refuses goals on the agent that shipped worktrees"
assert_fail cx_agent_goals_ok web1 0.2.0

summary
