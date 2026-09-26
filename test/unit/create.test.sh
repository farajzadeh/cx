#!/usr/bin/env bash
# Unit tests for creating and opening in one step — `cx new` and `cx wt add`
# with --open, and the questions they ask when run bare at a terminal.
#
# The agent and cmd_open are both stubbed and record what they were given.
# What is pinned is the client's half: which argv reaches the agent, which
# words reach cx open, that nothing is created when the options contradict
# each other, and — the part that must not move — that without a terminal a
# missing target is still exit 3, exactly as it was before any of this.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

export CX_HOME="$ROOT"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-create.XXXXXX")
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
# shellcheck source=../../lib/cmd/new.sh
. "$ROOT/lib/cmd/new.sh"
# shellcheck source=../../lib/cmd/wt.sh
. "$ROOT/lib/cmd/wt.sh"

# Only the --json checks need jq. The rest must run where it is missing too —
# the bash 3.2 image has none, and bash 3.2 is the point of running there.
HAVE_JQ=0
cx_have jq && HAVE_JQ=1

printf 'Host web1\n' >"$CX_SSHD_DIR/web1.conf"

export CX_PICKER=builtin CX_PICK_TTY_OUT="$TMP/screen"

# --- stubs -----------------------------------------------------------------
# Defined after the command files, which source lib/remote.sh and would put
# the real ones back over the top.

# The agent: every call appended to agent.log, one line each.
AGENT_RC=0
cx_agent() {
  shift # the host
  printf '%s\n' "$*" >>"$TMP/agent.log"
  case "$1" in
    version) printf '0.9.0\n' ;;
    new) printf '{"name":"%s","path":"/home/u/projects/%s"}\n' "$2" "$2" ;;
    worktree) printf '{"name":"%s","branch":"%s","path":"/p/%s"}\n' "$4" "$4" "$4" ;;
  esac
  return "$AGENT_RC"
}
cx_cache_invalidate() { printf '%s\n' "$1" >>"$TMP/invalidated"; }

# cx open: what it was asked to open, one line per call.
OPEN_RC=0
cmd_open() {
  printf '%s\n' "$*" >>"$TMP/open.log"
  if [ "${CX_JSON:-0}" = 1 ]; then
    printf '{"created":true,"target":"stub","host":"web1"}\n'
  fi
  return "$OPEN_RC"
}
# bin/cx's loader; cmd_open is already defined, which is all it checks.
load_cmd() { command -v "cmd_$1" >/dev/null 2>&1; }

# Pickers are tested in pick.test.sh. Here they record that they were asked.
cx_pick_host() {
  printf 'host\n' >>"$TMP/picked"
  printf 'web2\n'
}
cx_pick_target() {
  printf '%s\n' "$1" >>"$TMP/picked"
  printf 'web1:api\n'
}

TTY=1
_cx_pick_tty() { [ "$TTY" = 1 ]; }

# fresh [ANSWERS...] — clear every log, and set what the human will type.
fresh() {
  rm -f "$TMP/agent.log" "$TMP/open.log" "$TMP/picked" "$TMP/invalidated"
  : >"$TMP/screen"
  printf '%s\n' "$@" >"$TMP/keys"
  export CX_PICK_TTY_IN="$TMP/keys"
  cx_ask_reset
}
log() { cat "$TMP/$1" 2>/dev/null || true; }

# run CMD... — run a command in a subshell, stash its exit status in RC and
# its combined output in OUT.
run() {
  RC=0
  OUT=$("$@" 2>&1) || RC=$?
}

# ===========================================================================

describe "names are checked before a round trip"

it "accepts what the agent accepts"
for n in api my.app web_1 a-b; do
  assert_ok cx_project_name_ok "$n"
done
it "rejects what the agent would"
for n in "" . .. -x .worktrees "a b" "a/b" "a@b"; do
  assert_fail cx_project_name_ok "$n"
done
it "a worktree name has no dot, unlike a project name"
assert_fail cx_worktree_name_ok "my.fix"
it "and otherwise the same shape"
assert_ok cx_worktree_name_ok "bug-123"

# ===========================================================================

describe "cx new — without a terminal, nothing changes"

TTY=0

it "no target is still exit 3"
fresh
run cmd_new
assert_eq "$RC" 3
assert_eq "$(log agent.log)" "" "and nothing reached the agent"

it "and asks nothing"
assert_eq "$(cat "$TMP/screen")" ""

it "creates without opening, as before"
fresh
run cmd_new web1:app
assert_eq "$RC" 0
assert_eq "$(log agent.log)" "new app"
assert_eq "$(log open.log)" "" "and opens nothing"
assert_contains "$OUT" "start working: cx open web1:app" "and still suggests how"

it "CX_OPEN_AFTER_CREATE=always does not attach with no terminal to attach"
fresh
CX_OPEN_AFTER_CREATE=always run cmd_new web1:app
assert_eq "$(log open.log)" ""

describe "cx new --open and friends"

it "--open hands the new project to cx open"
fresh
run cmd_new web1:app --open
assert_eq "$RC" 0
assert_eq "$(log open.log)" "web1:app"

it "creates first, and invalidates the cache before opening"
assert_eq "$(log agent.log)" "new app"
assert_eq "$(log invalidated)" "web1"

it "and does not suggest opening what it has just opened"
assert_not_contains "$OUT" "start working"

it "-d implies --open, detached"
fresh
run cmd_new -d web1:app
assert_eq "$(log open.log)" "-d web1:app"

it "passes the permission flag through to cx open"
fresh
run cmd_new web1:app -d --dangerously-skip-permissions
assert_eq "$(log open.log)" "-d --dangerously-skip-permissions web1:app"

it "and the options that take a value, value included"
fresh
run cmd_new --model opus web1:app --effort high
assert_eq "$(log open.log)" "--model opus --effort high web1:app"

it "--label opens a labelled session, and is not taken for the target"
fresh
run cmd_new --label impl web1:app
assert_eq "$(log agent.log)" "new app"
assert_eq "$(log open.log)" "web1:app@impl"

it "--repo still works alongside"
fresh
run cmd_new web1:app --repo https://x/y.git --open
assert_eq "$(log agent.log)" "new app --repo https://x/y.git"

it "reports cx open failing, and says the project is there"
fresh
OPEN_RC=4
run cmd_new web1:app --open
OPEN_RC=0
assert_eq "$RC" 4
assert_contains "$OUT" "open it later with: cx open web1:app"

it "opens nothing when creating failed"
fresh
AGENT_RC=4
run cmd_new web1:app --open
AGENT_RC=0
assert_eq "$RC" 4
assert_eq "$(log open.log)" ""

describe "cx new — contradictions are refused before anything exists"

for args in "--open --no-open" "-d --no-open" "--no-open --label x" \
  "--permission-mode nonsense" "--label bad.dot" "--label"; do
  fresh
  # shellcheck disable=SC2086  # word-splitting the flags is the point
  run cmd_new web1:app $args
  assert_eq "$RC:$(log agent.log)" "3:" "refuses: $args"
done

it "names the option that clashes with --no-open"
fresh
run cmd_new web1:app --no-open -d
assert_contains "$OUT" "-d describes the session"

it "an @label in the target says where the label goes"
fresh
run cmd_new web1:app@impl
assert_eq "$RC" 3
assert_contains "$OUT" "--label impl"

describe "cx new --json"

it "--open without -d is refused: an attached session has no JSON"
fresh
CX_JSON=1 run cmd_new web1:app --open
assert_eq "$RC:$(log agent.log)" "3:"

if [ "$HAVE_JQ" = 1 ]; then
  it "-d gives one object, with the session inside it"
  fresh
  CX_JSON=1 run cmd_new web1:app -d
  assert_eq "$RC" 0
  assert_eq "$(printf '%s' "$OUT" | jq -r '.name + " " + .host + " " + (.session.created|tostring)')" \
    "app web1 true"

  it "without --open, the object it always printed"
  fresh
  CX_JSON=1 run cmd_new web1:app
  assert_eq "$(printf '%s' "$OUT" | jq -c '{name,host,session}')" \
    '{"name":"app","host":"web1","session":null}'
  assert_eq "$(log open.log)" "" "and opens nothing"
else
  it "the JSON it prints"
  skip "jq unavailable"
fi

# ===========================================================================

describe "cx new — at a terminal"

TTY=1

it "asks for the name, the repository, and whether to open"
fresh "app" "" ""
run cmd_new
assert_eq "$RC" 0
assert_eq "$(log agent.log)" "new app"
assert_eq "$(log open.log)" "web1:app"

it "does not ask which server when there is only one"
assert_eq "$(log picked)" ""

it "asks again after a name the agent would refuse"
fresh "bad name" "app" "" "n"
run cmd_new
assert_eq "$(log agent.log)" "new app"
assert_contains "$(cat "$TMP/screen")" "only letters, digits"

it "a repository answer becomes --repo"
fresh "app" "git@github.com:me/app.git" "n"
run cmd_new
assert_eq "$(log agent.log)" "new app --repo git@github.com:me/app.git"

it "and answering no opens nothing"
assert_eq "$(log open.log)" ""

it "does not ask for a repository when --repo was given"
fresh "app" "n"
run cmd_new --repo https://x/y.git
assert_eq "$(log agent.log)" "new app --repo https://x/y.git"

it "does not ask whether to open when --open or --no-open says"
fresh "app" ""
run cmd_new --no-open
assert_eq "$(log open.log)" ""
assert_not_contains "$(cat "$TMP/screen")" "Open a session"

it "picks the server when there is more than one"
printf 'Host web2\n' >"$CX_SSHD_DIR/web2.conf"
fresh "app" "" "n"
run cmd_new
assert_eq "$(log picked)" "host"
assert_contains "$OUT" "created web2:app"
rm -f "$CX_SSHD_DIR/web2.conf"

it "Ctrl-D at the name creates nothing, and exits 130"
fresh
: >"$TMP/keys"
run cmd_new
assert_eq "$RC:$(log agent.log)" "130:"

it "with a target given, still asks whether to open"
fresh "y"
run cmd_new web1:app
assert_eq "$(log open.log)" "web1:app"

it "unless CX_OPEN_AFTER_CREATE=never"
fresh "y"
CX_OPEN_AFTER_CREATE=never run cmd_new web1:app
assert_eq "$(log open.log)" ""

it "and CX_OPEN_AFTER_CREATE=always opens without asking"
fresh
CX_OPEN_AFTER_CREATE=always run cmd_new web1:app
assert_eq "$(log open.log)" "web1:app"

it "-y is never asked, and gets no session it did not ask for"
fresh "y"
CX_ASSUME_YES=1 run cmd_new web1:app
assert_eq "$(log open.log)" ""

it "-y with no target is still exit 3"
fresh "app"
CX_ASSUME_YES=1 run cmd_new
assert_eq "$RC" 3

it "--json with no target is still exit 3"
fresh "app"
CX_JSON=1 run cmd_new
assert_eq "$RC" 3

# ===========================================================================

describe "cx wt add — without a terminal, nothing changes"

TTY=0

it "no target is still exit 3"
fresh
run cmd_wt add
assert_eq "$RC:$(log agent.log)" "3:"

it "a project with no /name is still exit 3"
fresh
run cmd_wt add web1:api
assert_eq "$RC" 3
assert_contains "$OUT" "no worktree named"

it "creates without opening, as before"
fresh
run cmd_wt add web1:api/fix
assert_eq "$RC" 0
assert_contains "$(log agent.log)" "worktree add api fix"
assert_eq "$(log open.log)" ""

describe "cx wt add --open"

it "opens the new worktree"
fresh
run cmd_wt add web1:api/fix --open
assert_eq "$(log open.log)" "web1:api/fix"

it "with -d, the permission flag and a label"
fresh
run cmd_wt add -d --dangerously-skip-permissions web1:api/fix --label impl
assert_eq "$(log open.log)" "-d --dangerously-skip-permissions web1:api/fix@impl"

it "keeps --branch and --from its own"
fresh
run cmd_wt add web1:api/fix --branch b --from main -d
assert_contains "$(log agent.log)" "worktree add api fix --branch b --from main"
assert_eq "$(log open.log)" "-d web1:api/fix"

it "refuses --no-open with -d before creating anything"
fresh
run cmd_wt add web1:api/fix --no-open -d
assert_eq "$RC:$(log agent.log)" "3:"

it "--json -d gives one object, with the session inside it"
if [ "$HAVE_JQ" = 1 ]; then
  fresh
  CX_JSON=1 run cmd_wt add web1:api/fix -d
  assert_eq "$(printf '%s' "$OUT" | jq -r '.name + " " + (.session.created|tostring)')" "fix true"
else
  skip "jq unavailable"
fi

describe "cx wt add — at a terminal"

TTY=1

it "no target: picks the project, asks the name and branch"
fresh "fix" "" "n"
run cmd_wt add
assert_eq "$RC" 0
assert_eq "$(log picked)" "project"
assert_contains "$(log agent.log)" "worktree add api fix"

it "and accepting the default branch sends no --branch, as leaving it off does"
assert_not_contains "$(log agent.log)" "--branch"

it "a project with no /name: asks the name rather than failing"
fresh "fix" "feature-x" ""
run cmd_wt add web1:api
assert_eq "$RC" 0
assert_eq "$(log picked)" "" "without picking a project"
assert_contains "$(log agent.log)" "worktree add api fix --branch feature-x"
assert_eq "$(log open.log)" "web1:api/fix" "and opens it on an empty answer"

it "asks again after a worktree name with a dot"
fresh "my.fix" "fix" "" "n"
run cmd_wt add web1:api
assert_contains "$(log agent.log)" "worktree add api fix"
assert_contains "$(cat "$TMP/screen")" "only letters, digits"

it "does not ask for a branch when --branch was given"
fresh "fix" "n"
run cmd_wt add web1:api --branch mine
assert_contains "$(log agent.log)" "worktree add api fix --branch mine"

it "a full target at a terminal only asks whether to open"
fresh "y"
run cmd_wt add web1:api/fix
assert_eq "$(log open.log)" "web1:api/fix"

it "-y with a project and no /name is still exit 3"
fresh "fix"
CX_ASSUME_YES=1 run cmd_wt add web1:api
assert_eq "$RC" 3

summary
