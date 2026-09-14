#!/usr/bin/env bash
# Unit tests for the agent's observe verb, reached through CX_AGENT_NO_MAIN.
#
# observe is under every status-bar redraw, every peek and every nudge, so
# what it costs matters as much as what it says. These pin the facts it
# reports and the work it skips: a dead session's conversation is not parsed
# unless a tail was asked for, and a transcript is read from a byte window
# that escalates to a line window only when that window was not enough.
#
# tmux is replaced by a fixture: the machine running the tests may well have
# real cx sessions of its own, and observe must never see those here.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-observe.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export CX_DATA_DIR="$TMP/data" CX_CLAUDE_DIR="$TMP/claude"
export CX_REGISTRY="$TMP/data/projects.json" CX_SESSIONS="$TMP/data/sessions.json"
export CX_GOALS="$TMP/data/goals.json"
export CX_AGENT_NO_MAIN=1
mkdir -p "$CX_DATA_DIR"

# shellcheck source=../../server/cx-agent
. "$ROOT/server/cx-agent"
set +eu

if ! have jq; then
  describe "observe"
  it "needs jq"
  skip "jq unavailable"
  summary
  exit $?
fi

enc() { printf '%s' "$1" | tr -c 'A-Za-z0-9-' '-'; }

# transcript DIR UUID STOP — a conversation whose last main-thread turn ended
# with STOP, trailed by the bookkeeping and sidechain lines real ones carry.
transcript() {
  local d
  d="$CX_CLAUDE_DIR/projects/$(enc "$1")"
  mkdir -p "$d"
  {
    printf '{"type":"user","isSidechain":false,"message":{"role":"user","content":"go"}}\n'
    printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","stop_reason":"%s","content":[{"type":"text","text":"reply from %s"}]}}\n' "$3" "$2"
    printf '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","stop_reason":"tool_use","content":[]}}\n'
    printf '{"type":"last-prompt","prompt":"go"}\n'
  } >"$d/$2.jsonl"
}

mkdir -p "$TMP/api" "$TMP/my.app" "$TMP/unused"
cat >"$CX_REGISTRY" <<EOF
{"version":1,"root":"$TMP","projects":[
  {"name":"api","path":"$TMP/api"},
  {"name":"my.app","path":"$TMP/my.app"},
  {"name":"unused","path":"$TMP/unused"}]}
EOF
cat >"$CX_SESSIONS" <<'EOF'
{"version":1,"sessions":{
  "api":        {"uuid":"u-api"},
  "api@review": {"uuid":"u-review"},
  "my.app":     {"uuid":"u-myapp"},
  "unused":     {"uuid":"u-unused"}}}
EOF
transcript "$TMP/api" u-api end_turn
transcript "$TMP/api" u-review end_turn
transcript "$TMP/my.app" u-myapp tool_use
# u-unused has no transcript at all: opened once, never used, stopped.

# The fixture tmux: api and my.app are running, api@review is not. tmux has
# already mangled the dot, exactly as it does for real.
_tmux_rows() {
  printf 'cx-api\t0\t1700000000\t1\t1700000100\tclaude\n'
  printf 'cx-my_app\t1\t1700000000\t1\t1700000100\tclaude\n'
  printf 'unrelated\t0\t1700000000\t1\t1700000100\tbash\n'
}

OBS=$(cmd_observe --all --tail 0)
target() { printf '%s' "$OBS" | jq -c --arg t "$1" '.sessions[] | select(.target == $t)'; }

describe "observe --all — which sessions it reports"

it "reports a live session"
assert_eq "$(target api | jq -r .tmux.alive)" true

it "recovers a dotted project name that tmux mangled"
assert_eq "$(target my.app | jq -r .tmux.alive)" true

it "reports a dead session that still has a conversation"
assert_eq "$(target api@review | jq -r .tmux.alive)" false

it "leaves out a pinned session with no tmux and no conversation"
assert_eq "$(target unused)" ""

it "ignores tmux sessions cx did not start"
assert_eq "$(target unrelated)" ""

it "attributes attached clients to the right session"
assert_eq "$(target my.app | jq -r .tmux.attached)" true

describe "observe --all — what it reads"

it "reads a live session's last turn"
assert_eq "$(target api | jq -r .last.stop_reason)" end_turn

it "finds the transcript under the byte-encoded directory"
assert_eq "$(target my.app | jq -r .transcript.present)" true

it "does not parse a dead session's conversation when no tail was asked for"
# Its state is dead whatever that conversation says, so reading it bought
# nothing — and on a real server, 23 of 26 sessions were dead.
assert_eq "$(target api@review | jq -r .last)" null

it "still reports the dead session's transcript facts without reading it"
assert_eq "$(target api@review | jq -r .transcript.present)" true

it "reads a dead session's conversation once a tail is asked for"
# That is how a driver decides whether a dead session is worth reviving.
assert_eq \
  "$(cmd_observe --all --tail 2 | jq -r '.sessions[] | select(.target == "api@review") | .last.text')" \
  "reply from u-review"

it "keeps --tail to the number of messages asked for"
assert_eq \
  "$(cmd_observe --all --tail 1 | jq -r '.sessions[] | select(.target == "api") | .tail | length')" \
  1

describe "observe <name> — one named session"

it "reports a session it was asked about even with nothing to say"
assert_eq "$(cmd_observe unused | jq -r '.sessions | length')" 1

it "reports a project that does not exist rather than failing"
run_rc cmd_observe no-such-project
assert_eq "$_T_RC" 0

describe "observe --unit and --slug — narrowing on the server"

targets() { jq -r '[.sessions[].target] | sort | join(",")'; }

it "narrows to a project and its labelled sessions"
assert_eq "$(cmd_observe --all --unit api --tail 0 | targets)" "api,api@review"

it "narrows to one labelled session"
assert_eq "$(cmd_observe --all --unit api@review --tail 0 | targets)" "api@review"

it "does not let a unit swallow another project that starts the same way"
# "api" must not take a project called "apiary" — only "api" and "api@...".
mkdir -p "$TMP/apiary"
jq --arg p "$TMP/apiary" '.projects += [{name: "apiary", path: $p}]' "$CX_REGISTRY" >"$TMP/r" && mv "$TMP/r" "$CX_REGISTRY"
jq '.sessions.apiary = {uuid: "u-apiary"}' "$CX_SESSIONS" >"$TMP/s" && mv "$TMP/s" "$CX_SESSIONS"
transcript "$TMP/apiary" u-apiary end_turn
assert_eq "$(cmd_observe --all --unit api --tail 0 | targets)" "api,api@review"

it "picks exact sessions with --slug"
assert_eq "$(cmd_observe --all --slug api --tail 0 | targets)" "api"

it "takes several --slug at once"
assert_eq "$(cmd_observe --all --slug api --slug my.app --tail 0 | targets)" "api,my.app"

it "reports a --slug that is neither running nor has a conversation"
# A goal member nobody has opened yet is still a member; the driver needs to
# see it is not there rather than have it silently vanish from the answer.
assert_eq "$(cmd_observe --all --slug never-opened --tail 0 | targets)" "never-opened"

it "implies --all"
assert_eq "$(cmd_observe --unit my.app --tail 0 | targets)" "my.app"

describe "observe — what Claude and its hooks report"

export CX_STATE_DIR="$TMP/data/state"
mkdir -p "$CX_CLAUDE_DIR/sessions" "$CX_STATE_DIR"

# A dead pid: start something, let it finish, keep its number.
sleep 0 &
DEAD=$!
wait "$DEAD" 2>/dev/null

MYSTART=""
[ -r "/proc/$$/stat" ] && MYSTART=$(sed 's/.*) //' "/proc/$$/stat" | awk '{print $20}')

printf '{"pid":%s,"sessionId":"u-api","procStart":"%s","kind":"interactive","tmux":"cx-api:@1.%%1","status":"busy","statusUpdatedAt":1700000200000}\n' \
  "$$" "$MYSTART" >"$CX_CLAUDE_DIR/sessions/$$.json"
printf '{"pid":%s,"sessionId":"u-review","kind":"interactive","status":"idle","statusUpdatedAt":1700000200000}\n' \
  "$DEAD" >"$CX_CLAUDE_DIR/sessions/$DEAD.json"
printf '{"pid":%s,"sessionId":"u-myapp","procStart":"1","kind":"interactive","status":"idle"}\n' \
  "$$" >"$CX_CLAUDE_DIR/sessions/reused.json"
printf 'not json\n' >"$CX_CLAUDE_DIR/sessions/garbage.json"

OBS=$(cmd_observe --all --tail 0)

it "reports Claude's own status for a session whose process is running"
assert_eq "$(target api | jq -r .claude.status)" busy

it "reports when that status was last updated, in seconds"
assert_eq "$(target api | jq -r .claude.at)" 1700000200

it "ignores a status file whose process has exited"
assert_eq "$(target api@review | jq -r .claude)" null

it "ignores a status file whose pid now belongs to a different process"
# Seen for real: two status files on one machine passed kill -0 because their
# pids had been reused. The start time is what tells them apart.
if [ -n "$MYSTART" ]; then
  assert_eq "$(target my.app | jq -r .claude)" null
else
  skip "no /proc on this system"
fi

it "survives a status file that is not JSON"
assert_eq "$(target api | jq -r .target)" api

it "reports what the hooks last said, while the session is up"
printf 'blocked\t%s\tPermissionRequest\tneeds Bash\n' "$(date +%s)" >"$CX_STATE_DIR/u-api"
assert_eq "$(cmd_observe --all --tail 0 | jq -r '.sessions[] | select(.target == "api") | .event.state')" blocked

it "names the hook that said it"
assert_eq "$(cmd_observe --all --tail 0 | jq -r '.sessions[] | select(.target == "api") | .event.via')" PermissionRequest

it "ignores a report older than the tmux session it would describe"
# The file is keyed by conversation, and a conversation outlives its session:
# this report was left by whatever held it before tmux started this one.
printf 'blocked\t1600000000\tPermissionRequest\t\n' >"$CX_STATE_DIR/u-api"
assert_eq "$(cmd_observe --all --tail 0 | jq -r '.sessions[] | select(.target == "api") | .event')" null

it "ignores a report for a session that is not running"
printf 'working\t%s\tPreToolUse\t\n' "$(date +%s)" >"$CX_STATE_DIR/u-review"
assert_eq "$(cmd_observe --all --tail 0 | jq -r '.sessions[] | select(.target == "api@review") | .event')" null

rm -rf "$CX_CLAUDE_DIR/sessions" "$CX_STATE_DIR"

describe "_transcript_messages — the byte window and its escalation"

BIG="$TMP/big.jsonl"
{
  printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"the real last turn"}]}}\n'
  i=0
  while [ $i -lt 60 ]; do
    printf '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"text","text":"sidechain noise %s"}]}}\n' "$i"
    i=$((i + 1))
  done
} >"$BIG"

it "escalates past a byte window that holds only sidechain"
assert_eq \
  "$(CX_OBSERVE_BYTES=400 _transcript_messages "$BIG" | tail -n 1 | jq -r .text)" \
  "the real last turn"

it "does not escalate when the byte window is the whole file"
SMALL="$TMP/small.jsonl"
printf '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","stop_reason":"tool_use","content":[]}}\n' >"$SMALL"
assert_eq "$(CX_OBSERVE_BYTES=100000 _transcript_messages "$SMALL")" ""

it "survives a window that starts in the middle of a line"
# Cut at an arbitrary byte, the first line is half an object by construction.
assert_eq \
  "$(CX_OBSERVE_BYTES=180 _transcript_messages "$TMP/claude/projects/$(enc "$TMP/api")/u-api.jsonl" | tail -n 1 | jq -r .stop_reason)" \
  end_turn

it "escalates when fewer messages were found than wanted"
MANY="$TMP/many.jsonl"
{
  for n in 1 2 3; do
    printf '{"type":"user","isSidechain":false,"message":{"role":"user","content":"turn %s"}}\n' "$n"
    i=0
    while [ $i -lt 20 ]; do
      printf '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[]}}\n'
      i=$((i + 1))
    done
  done
} >"$MANY"
assert_eq "$(CX_OBSERVE_BYTES=300 _transcript_messages "$MANY" 3 | grep -c .)" 3

summary
