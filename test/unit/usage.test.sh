#!/usr/bin/env bash
# Unit tests for `cx usage`: the agent's usage verb, which reads Claude's
# transcripts and its own usage readings on the server, and the client that
# asks every server and wraps the answers.
#
# The agent half runs against a session store built here, in the layout and
# shapes a real one has (verified against Claude Code 2.1.303): one line per
# content block with the message's id and usage on each, output growing from
# line to line; subagents in <session>/subagents/; a last line still being
# written. The client half stubs cx_agent, as peek.test.sh does.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-usage.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

if ! command -v jq >/dev/null 2>&1; then
  describe "cx usage"
  it "needs jq"
  skip "jq unavailable"
  summary
  exit $?
fi

# ---------------------------------------------------------------------------
# The agent
# ---------------------------------------------------------------------------

export CX_DATA_DIR="$TMP/data" CX_CLAUDE_DIR="$TMP/claude"
export CX_REGISTRY="$TMP/data/projects.json" CX_SESSIONS="$TMP/data/sessions.json"
export CX_GOALS="$TMP/data/goals.json" CX_STATE_DIR="$TMP/data/state"
export CX_CLAUDE_JSON="$TMP/claude.json"
export CX_USAGE_DIR="$TMP/data/usage"
mkdir -p "$CX_DATA_DIR" "$CX_STATE_DIR" "$CX_CLAUDE_DIR/projects" "$TMP/projects"
AGENT="$ROOT/server/cx-agent"

P="$TMP/projects"
mkdir -p "$P/api" "$P/web"
HAVE_GIT=0
if command -v git >/dev/null 2>&1 &&
  git -C "$P/api" init -q 2>/dev/null &&
  git -C "$P/api" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init 2>/dev/null &&
  git -C "$P/api" worktree add -q -b fix-1 "$P/.worktrees/api/fix-1" 2>/dev/null; then
  HAVE_GIT=1
fi
jq -n --arg api "$P/api" --arg web "$P/web" \
  '{version: 1, root: "", projects: [{name: "api", path: $api}, {name: "web", path: $web}]}' >"$CX_REGISTRY"

# enc PATH — the store's directory for PATH, by the agent's own rule.
enc() { CX_AGENT_NO_MAIN=1 bash -c '. "$1"; _session_dir_name "$2"' _ "$AGENT" "$1"; }
D_API="$CX_CLAUDE_DIR/projects/$(enc "$P/api")"
D_WT="$CX_CLAUDE_DIR/projects/$(enc "$P/.worktrees/api/fix-1")"
D_GONE="$CX_CLAUDE_DIR/projects/$(enc "$P/.worktrees/api/old-2")"
D_WEB="$CX_CLAUDE_DIR/projects/$(enc "$P/web")"
D_OTHER="$CX_CLAUDE_DIR/projects/-home-someone-scratch"
mkdir -p "$D_API/s1/subagents" "$D_WT" "$D_GONE" "$D_WEB" "$D_OTHER"

TODAY=$(jq -rn 'now | todate | .[0:10]')
YESTERDAY=$(jq -rn 'now - 86400 | todate | .[0:10]')
OLD=$(jq -rn 'now - 40 * 86400 | todate | .[0:10]')
SINCE30=$(jq -rn 'now - 29 * 86400 | todate | .[0:10]')

# msg ID DATE IN OUT CACHE_READ CACHE_WRITE — one assistant line, the way Claude
# writes one content block of a message.
msg() {
  printf '{"parentUuid":null,"isSidechain":false,"type":"assistant","timestamp":"%sT10:00:00.000Z","message":{"model":"claude-opus-5-5","id":"%s","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":null,"usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":%s},"output_tokens":%s,"service_tier":"standard"}},"requestId":"req_%s","uuid":"%s-%s"}\n' \
    "$2" "$1" "$3" "$6" "$5" "$6" "$4" "$1" "$1" "$RANDOM"
}
# A user line that mentions both words the prefilter looks for, and is not a message.
user_line() {
  printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"the \\"assistant\\" printed \\"usage\\""}]},"uuid":"x-%s","timestamp":"%sT10:00:00.000Z"}\n' "$RANDOM" "$TODAY"
}

{
  msg a1 "$TODAY" 10 3 1000 50
  user_line
  msg a1 "$TODAY" 10 3 1000 50
  msg a1 "$TODAY" 10 700 1000 50
  msg a2 "$YESTERDAY" 5 20 0 0
} >"$D_API/s1.jsonl"
msg s1 "$TODAY" 1 2 3 4 >"$D_API/s1/subagents/agent-a1b2.jsonl"
msg w1 "$TODAY" 100 100 0 0 >"$D_WT/w.jsonl"
msg g1 "$TODAY" 7 7 0 0 >"$D_GONE/g.jsonl"
msg o1 "$TODAY" 1000 0 0 0 >"$D_OTHER/o.jsonl"
{
  # a2 again, carried into another conversation: counted once, on its
  # earliest date and so in api.
  msg a2 "$TODAY" 5 20 0 0
  msg wb1 "$TODAY" 2 2 0 1
  msg old1 "$OLD" 9 9 0 0
} >"$D_WEB/w1.jsonl"
# A transcript nobody has touched in a hundred days holds nothing a window
# counts, whatever it says.
msg z1 "$TODAY" 99999 0 0 0 >"$D_WEB/stale.jsonl"
touch -t "$(jq -rn 'now - 100 * 86400 | strflocaltime("%Y%m%d%H%M")')" "$D_WEB/stale.jsonl"
# The last line is one Claude is still writing.
{
  msg h1 "$TODAY" 1 1 0 0
  msg h2 "$TODAY" 50 50 0 0 | head -c 120
} >"$D_API/s2.jsonl"

usage() { "$AGENT" usage "$@" 2>"$TMP/stderr"; }
OUT=$(usage --days 30)

describe "cx-agent usage — tokens from the transcripts"

it "prints one JSON object, and nothing on stderr"
assert_eq "$(printf '%s' "$OUT" | jq -r 'type')" "object"
assert_eq "$(cat "$TMP/stderr")" ""

it "says which day it counts from"
assert_eq "$(printf '%s' "$OUT" | jq -r '.since')" "$SINCE30"

it "keeps the largest figures of a message written over several lines"
# a1: three lines, output 3, 3, 700. Summed it would be 706; counted once, 700.
assert_eq "$(printf '%s' "$OUT" | jq -c --arg d "$TODAY" '.days[] | select(.date == $d) | [.input, .output, .cache_read, .cache_write, .messages]')" \
  '[1121,812,1003,55,7]'

it "puts each message on its own day"
assert_eq "$(printf '%s' "$OUT" | jq -c --arg d "$YESTERDAY" '.days[] | select(.date == $d) | [.input, .output, .messages]')" '[5,20,1]'

it "lists days oldest first, and only days with messages"
assert_eq "$(printf '%s' "$OUT" | jq -c '[.days[].date]')" "[\"$YESTERDAY\",\"$TODAY\"]"

it "counts subagents, worktrees and removed worktrees under their project"
assert_eq "$(printf '%s' "$OUT" | jq -c '.projects[] | select(.project == "api") | [.input, .output, .cache_read, .cache_write, .messages]')" \
  '[124,830,1003,54,6]'

it "counts a message carried into a second transcript once"
assert_eq "$(printf '%s' "$OUT" | jq -c '.projects[] | select(.project == "web") | [.input, .output, .cache_write, .messages]')" '[2,2,1,1]'

it "keeps work outside every project, under project null"
assert_eq "$(printf '%s' "$OUT" | jq -c '.projects[] | select(.project == null) | [.input, .messages]')" '[1000,1]'

it "sorts projects by new tokens, most first"
assert_eq "$(printf '%s' "$OUT" | jq -c '[.projects[].project]')" '["api",null,"web"]'

it "leaves out messages from before the window"
assert_eq "$(printf '%s' "$OUT" | jq -c --arg d "$OLD" '[.days[] | select(.date == $d)] | length')" "0"

it "and counts them in a window that reaches back far enough"
assert_eq "$(usage --days 45 | jq -c --arg d "$OLD" '[.days[] | select(.date == $d) | .input]')" "[9]"

it "ignores a transcript last touched before the window"
assert_not_contains "$OUT" "99999"

it "skips the line Claude is still writing"
assert_eq "$(printf '%s' "$OUT" | jq -r '[.days[].input] | add')" "1126"

printf '%s\n' "$(msg h2 "$TODAY" 50 50 0 0 | tail -c +121)" >>"$D_API/s2.jsonl"
OUT=$(usage --days 30)
it "and counts it once it is whole"
assert_eq "$(printf '%s' "$OUT" | jq -c --arg d "$TODAY" '.days[] | select(.date == $d) | [.input, .output, .messages]')" '[1171,862,8]'

msg n1 "$TODAY" 3 4 5 6 >>"$D_API/s1.jsonl"
msg a1 "$TODAY" 10 900 1000 50 >>"$D_API/s1.jsonl"
INC=$(usage --days 30)
rm -rf "$CX_USAGE_DIR"
FULL=$(usage --days 30)
it "reads only what was appended, and agrees with a run from nothing"
assert_eq "$(printf '%s' "$INC" | jq -c 'del(.observed_at)')" "$(printf '%s' "$FULL" | jq -c 'del(.observed_at)')"

it "including a later line of a message it had already counted"
assert_eq "$(printf '%s' "$INC" | jq -c --arg d "$TODAY" '.days[] | select(.date == $d) | [.input, .output, .messages]')" '[1174,1066,9]'

it "and the same again from what it kept (invariant 4)"
assert_eq "$(usage --days 30 | jq -c 'del(.observed_at)')" "$(printf '%s' "$FULL" | jq -c 'del(.observed_at)')"

: >"$D_API/s2.jsonl"
it "starts a transcript over when it is smaller than what was read"
assert_eq "$(usage --days 30 | jq -c --arg d "$TODAY" '.days[] | select(.date == $d) | [.input, .messages]')" '[1123,7]'

printf 'garbage\tnot\ta\trow\n' >>"$CX_USAGE_DIR/$(enc "$P/web")/w1.jsonl.rows"
it "takes no harm from a damaged cache row"
assert_eq "$(usage --days 30 | jq -c --arg d "$TODAY" '.days[] | select(.date == $d) | [.input, .messages]')" '[1123,7]'

rm -f "$D_OTHER/o.jsonl"
usage --days 30 >/dev/null
it "forgets what it read of a transcript that is gone"
assert_eq "$(find "$CX_USAGE_DIR" -name 'o.jsonl.*' | wc -l | tr -d ' ')" "0"

it "counts a worktree made by hand outside cx's own directory under its project"
if [ "$HAVE_GIT" = 1 ] && git -C "$P/api" worktree add -q -b hand "$TMP/elsewhere/hand" 2>/dev/null; then
  BEFORE=$(usage --days 30 | jq '.projects[] | select(.project == "api") | .input')
  mkdir -p "$CX_CLAUDE_DIR/projects/$(enc "$TMP/elsewhere/hand")"
  msg e1 "$TODAY" 4 4 0 0 >"$CX_CLAUDE_DIR/projects/$(enc "$TMP/elsewhere/hand")/e.jsonl"
  assert_eq "$(usage --days 30 | jq '.projects[] | select(.project == "api") | .input')" "$((BEFORE + 4))"
else
  skip "git unavailable"
fi

describe "cx-agent usage — the limits Claude reported"

it "reports none when Claude has left none"
assert_eq "$(usage | jq -c '.limits')" "null"

NOW=$(date +%s)
iso() { jq -rn --argjson t "$1" '($t | todate | .[0:19]) + ".463080+00:00"'; }
cat >"$CX_CLAUDE_JSON" <<EOF
{"oauthAccount":{"accountUuid":"secret-uuid-1234","emailAddress":"someone@example.com"},
 "cachedUsageUtilization":{"fetchedAtMs":$(((NOW - 600) * 1000)),"accountUuid":"secret-uuid-1234",
  "utilization":{"five_hour":{"utilization":18,"resets_at":"$(iso $((NOW + 3600)))"},
   "seven_day":{"utilization":57,"resets_at":"$(iso $((NOW + 172800)))"}}}}
EOF
L=$(usage | jq -c '.limits')

it "reads Claude's own copy of its usage screen"
assert_eq "$(printf '%s' "$L" | jq -c '[.five_hour.pct, .seven_day.pct, .source, .at]')" "[18,57,\"usage\",$((NOW - 600))]"

it "with its reset times, as unix seconds"
assert_eq "$(printf '%s' "$L" | jq -r '.five_hour.resets_at')" "$((NOW + 3600))"

it "and nothing else from that file"
assert_not_contains "$(usage)" "secret-uuid"
assert_not_contains "$(usage)" "example.com"

printf '{"session_id":"s","rate_limits":{"five_hour":{"used_percentage":23,"resets_at":%s},"seven_day":{"used_percentage":41,"resets_at":%s}}}\n' \
  $((NOW + 1800)) $((NOW + 90000)) >"$CX_STATE_DIR/11111111-2222-3333-4444-555555555555.line"
L=$(usage | jq -c '.limits')
it "prefers a newer status line"
assert_eq "$(printf '%s' "$L" | jq -c '[.five_hour.pct, .five_hour.resets_at, .seven_day.pct, .source]')" "[23,$((NOW + 1800)),41,\"statusline\"]"

touch -t "$(jq -rn --argjson t $((NOW - 7200)) '$t | strflocaltime("%Y%m%d%H%M")')" "$CX_STATE_DIR/11111111-2222-3333-4444-555555555555.line"
it "and a newer copy of the usage screen to an older status line"
assert_eq "$(usage | jq -r '.limits.source')" "usage"

cat >"$CX_CLAUDE_JSON" <<EOF
{"cachedUsageUtilization":{"fetchedAtMs":$((NOW * 1000)),
  "utilization":{"five_hour":null,"seven_day":{"utilization":57,"resets_at":"$(iso $((NOW - 60)))"}}}}
EOF
it "reports a window it has no figure for as null"
assert_eq "$(usage | jq -c '.limits.five_hour')" "null"

it "and a window that has reset since, as it was: the caller decides"
assert_eq "$(usage | jq -c '[.limits.seven_day.pct, .limits.seven_day.resets_at]')" "[57,$((NOW - 60))]"

describe "cx-agent usage — one encoding rule"

it "encodes many paths exactly as it encodes one"
WANT=$(for p in "$P/api" "$P/.worktrees/api/fix-1" "/srv/my app/x.y" "/a/b-c_d"; do
  enc "$p"
  printf '\n'
done)
GOT=$(printf '%s\n' "$P/api" "$P/.worktrees/api/fix-1" "/srv/my app/x.y" "/a/b-c_d" |
  CX_AGENT_NO_MAIN=1 bash -c '. "$1"; _session_dir_names' _ "$AGENT")
assert_eq "$GOT" "$WANT"

describe "cx-agent usage — degrading and refusing"

it "answers with nothing counted when there is no session store"
assert_eq "$(CX_CLAUDE_DIR="$TMP/nowhere" "$AGENT" usage | jq -c '[.days, .projects]')" '[[],[]]'

it "refuses a window it does not take"
assert_exit 3 "$AGENT" usage --days 0
assert_exit 3 "$AGENT" usage --days 91
assert_exit 3 "$AGENT" usage --days ten
assert_exit 3 "$AGENT" usage --days
assert_exit 3 "$AGENT" usage --frobnicate

it "lists usage among its capabilities"
assert_eq "$("$AGENT" doctor 2>/dev/null | jq -r '.capabilities | index("usage") != null')" "true"

it "and in its usage text"
assert_contains "$("$AGENT" help 2>&1)" "usage [--days N]"

# ---------------------------------------------------------------------------
# The client
# ---------------------------------------------------------------------------

export CX_HOME="$ROOT"
export CX_CACHE_DIR="$TMP/cache" CX_SSHD_DIR="$TMP/ssh.d"
export CX_CONFIG_FILE="$TMP/no-such-config"
mkdir -p "$CX_SSHD_DIR"
for h in web1 old1 down1; do printf 'Host %s\n' "$h" >"$CX_SSHD_DIR/$h.conf"; done

(
  # shellcheck source=../../lib/compat.sh
  . "$ROOT/lib/compat.sh"
  # shellcheck source=../../lib/config.sh
  . "$ROOT/lib/config.sh"
  # shellcheck source=../../lib/ui.sh
  . "$ROOT/lib/ui.sh"
  # shellcheck source=../../lib/cache.sh
  . "$ROOT/lib/cache.sh"
  cx_config_load
  # shellcheck source=../../lib/cmd/usage.sh
  . "$ROOT/lib/cmd/usage.sh"

  ANSWER=$(printf '%s' "$FULL" | jq -c --argjson now "$NOW" '.limits = {five_hour: {pct: 23, resets_at: ($now + 1800)}, seven_day: {pct: 41, resets_at: ($now + 90000)}, at: ($now - 120), source: "statusline"}')
  # Stubbed after usage.sh, which pulls in lib/remote.sh and would otherwise
  # define the real cx_agent over the top. Every call is logged, one per line.
  cx_agent() {
    local host="$1"
    shift
    printf '%s %s\n' "$host" "$*" >>"$TMP/agent.log"
    case "$host $*" in
      "web1 version") printf '0.7.0\n' ;;
      "old1 version") printf '0.6.0\n' ;;
      "down1 "*) return 255 ;;
      "web1 usage "*) printf '%s\n' "$ANSWER" ;;
      *) return 3 ;;
    esac
  }

  describe "cx usage — the client"

  J=$(CX_JSON=1 cmd_usage 2>/dev/null)
  it "asks every server, and says which window"
  assert_eq "$(printf '%s' "$J" | jq -c '[.days, [.hosts[].host]]')" '[30,["down1","old1","web1"]]'

  it "wraps each answer with its host"
  assert_eq "$(printf '%s' "$J" | jq -c '.hosts[] | select(.host == "web1") | [.ok, .error, .since, (.days | length)]')" \
    "[true,null,\"$SINCE30\",$(printf '%s' "$FULL" | jq '.days | length')]"

  it "reports an agent too old for usage, with both versions"
  assert_eq "$(printf '%s' "$J" | jq -r '.hosts[] | select(.host == "old1") | [.ok, .error] | @tsv')" \
    "false	the cx agent is too old for cx usage (it reports 0.6.0; this needs 0.7.0)"

  it "never asks an old agent a verb it does not have"
  assert_not_contains "$(cat "$TMP/agent.log")" "old1 usage"

  it "reports a server it cannot reach, with every figure null"
  assert_eq "$(printf '%s' "$J" | jq -c '.hosts[] | select(.host == "down1") | [.ok, .error, .limits, .days, .projects]')" \
    '[false,"unreachable",null,null,null]'

  : >"$TMP/agent.log"
  J=$(CX_JSON=1 cmd_usage web1 --days 7 2>/dev/null)
  it "asks just the servers named, for the window asked"
  assert_eq "$(printf '%s' "$J" | jq -c '[.days, [.hosts[].host]]')" '[7,["web1"]]'
  assert_contains "$(cat "$TMP/agent.log")" "web1 usage --days 7"

  it "refuses a server it does not know, as other commands do"
  run_rc cmd_usage nosuch
  assert_eq "$_T_RC" "2"

  it "refuses a window the agent would"
  run_rc cmd_usage --days 0
  assert_eq "$_T_RC" "3"
  run_rc cmd_usage --days 1000
  assert_eq "$_T_RC" "3"

  OUTH=$(cmd_usage 2>"$TMP/stderr")
  it "shows a person the limits, the days and the projects"
  assert_contains "$OUTH" "5h 23%"
  assert_contains "$OUTH" "7d 41%"
  assert_contains "$OUTH" "(as of 2m ago)"
  assert_contains "$OUTH" "NEW TOKENS"
  assert_contains "$OUTH" "(no project)"

  it "and says why a server is missing"
  assert_contains "$(cat "$TMP/stderr")" "old1 runs an agent too old for cx usage"
  assert_contains "$(cat "$TMP/stderr")" "down1 unreachable"

  it "is in the usage text"
  assert_contains "$(CX_HOME="$ROOT" "$ROOT/bin/cx" help)" "usage [host] [--days N]"

  summary
) || exit 1
