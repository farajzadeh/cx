#!/usr/bin/env bash
# Unit tests for the tmux bar the agent draws on a cx session: `statusline`,
# which Claude runs to report context, cost and usage limits, and
# `tmux-status`, which tmux runs to draw them.
#
# Both answer to a program rather than a person. Claude shows whatever
# statusline prints under its prompt box, so cx's own output must never land
# there; tmux redraws the bar every few seconds and can do nothing with an
# error, so every failure is an empty line and exit 0. tmux itself is stubbed:
# what matters is what the agent reads and prints, not tmux's drawing.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-statusbar.XXXXXX")
export CX_DATA_DIR="$TMP/data" CX_CLAUDE_DIR="$TMP/claude"
export CX_REGISTRY="$TMP/data/projects.json" CX_SESSIONS="$TMP/data/sessions.json"
export CX_GOALS="$TMP/data/goals.json" CX_STATE_DIR="$TMP/data/state"
export CX_AGENT_NO_MAIN=1
mkdir -p "$CX_DATA_DIR" "$CX_CLAUDE_DIR/sessions" "$CX_STATE_DIR"

# shellcheck source=../../server/cx-agent
. "$ROOT/server/cx-agent"
set +eu

OTHER=""
trap '[ -n "$OTHER" ] && kill "$OTHER" 2>/dev/null; rm -rf "$TMP"' EXIT

if ! have jq; then
  describe "tmux bar"
  it "needs jq"
  skip "jq unavailable"
  summary
  exit $?
fi

# ---------------------------------------------------------------------------

describe "_launch_settings — what a launch hands Claude"

it "routes the status line to statusline when asked"
assert_eq "$(_launch_settings /a/cx-agent 1 1 | jq -r '.statusLine.command')" "'/a/cx-agent' statusline"

it "as a command, with no padding of its own"
assert_eq "$(_launch_settings /a/cx-agent 1 1 | jq -c '.statusLine | [.type, .padding]')" '["command",0]'

it "keeps the hooks beside it"
assert_eq "$(_launch_settings /a/cx-agent 1 1 | jq -r '.hooks.Stop[0].hooks[0].command')" "'/a/cx-agent' event"

it "can carry a status line without hooks, for open --no-hooks"
assert_eq "$(_launch_settings /a/cx-agent 0 1 | jq -c 'keys')" '["statusLine"]'

it "and hooks without a status line, for open --bar off"
assert_eq "$(_launch_settings /a/cx-agent 1 0 | jq -c 'keys')" '["hooks"]'

it "leaves _hook_settings exactly the hooks it always was"
assert_eq "$(_hook_settings /a/cx-agent | jq -c 'keys')" '["hooks"]'

# ---------------------------------------------------------------------------

# What real Claude Code 2.1.272 handed a status line after one turn, trimmed.
SID=11111111-2222-3333-4444-555555555555
PROJ="$TMP/proj"
mkdir -p "$PROJ"
line_json() {
  cat <<EOF
{"session_id":"$SID","transcript_path":"$TMP/claude/projects/x/$SID.jsonl","cwd":"$PROJ",
 "workspace":{"current_dir":"$PROJ","project_dir":"$PROJ"},
 "model":{"id":"claude-opus-5[1m]","display_name":"Opus 5 (1M context)"},
 "cost":{"total_cost_usd":1.2345,"total_lines_added":12,"total_lines_removed":3},
 "context_window":{"context_window_size":1000000,"used_percentage":8,
   "current_usage":{"input_tokens":10,"output_tokens":58,"cache_creation_input_tokens":4000,"cache_read_input_tokens":75400}},
 "rate_limits":{"five_hour":{"used_percentage":9,"resets_at":1789509000},
   "seven_day":{"used_percentage":56.00000000000001,"resets_at":1789603200}}}
EOF
}

# statusline [STDIN] — run it as Claude would, capturing stdout and status.
statusline() {
  printf '%s' "$1" | cmd_statusline >"$TMP/stdout" 2>"$TMP/stderr"
  _T_RC=$?
}

describe "cx-agent statusline — run by Claude"

statusline "$(line_json)"

it "exits 0"
assert_eq "$_T_RC" 0

it "keeps what Claude reported, under the conversation's id"
assert_eq "$(jq -r '.context_window.used_percentage' "$CX_STATE_DIR/$SID.line")" 8

it "prints nothing of cx's own under Claude's prompt box"
assert_eq "$(cat "$TMP/stdout")" ""

it "exits 0 with nothing on stdin"
statusline ""
assert_eq "$_T_RC" 0

it "exits 0 on input that is not JSON"
statusline "not json at all"
assert_eq "$_T_RC" 0

it "never writes outside the state directory, whatever the id says"
statusline '{"session_id":"../../escaped"}'
assert_eq "$(find "$TMP" -name '*escaped*' | wc -l | tr -d ' ')" 0

describe "statusline keeps the user's own status line"

mkdir -p "$CX_CLAUDE_DIR"
printf '{"statusLine":{"type":"command","command":"cat >%s/own-input; echo MY-LINE"}}\n' "$TMP" \
  >"$CX_CLAUDE_DIR/settings.json"
statusline "$(line_json)"

it "runs the command in their settings.json"
assert_eq "$(cat "$TMP/stdout")" MY-LINE

it "with the same input Claude gave cx"
assert_eq "$(jq -r '.session_id' "$TMP/own-input")" "$SID"

it "and still keeps cx's copy"
assert_ok test -s "$CX_STATE_DIR/$SID.line"

mkdir -p "$PROJ/.claude"
printf '{"statusLine":{"type":"command","command":"echo PROJECT-LINE"}}\n' >"$PROJ/.claude/settings.json"
statusline "$(line_json)"

it "prefers the project's settings to the user's, as Claude does"
assert_eq "$(cat "$TMP/stdout")" PROJECT-LINE

printf '{"statusLine":{"type":"command","command":"echo LOCAL-LINE"}}\n' >"$PROJ/.claude/settings.local.json"
statusline "$(line_json)"

it "and the project's local settings to both"
assert_eq "$(cat "$TMP/stdout")" LOCAL-LINE

rm -rf "$PROJ/.claude"
printf '{"statusLine":{"type":"command","command":"echo NESTED"}}\n' >"$CX_CLAUDE_DIR/settings.json"

it "does not run itself again from inside a status line it started"
printf '%s' "$(line_json)" | CX_STATUSLINE_NESTED=1 cmd_statusline >"$TMP/stdout" 2>/dev/null
assert_eq "$(cat "$TMP/stdout")" ""

rm -f "$CX_CLAUDE_DIR/settings.json"

# ---------------------------------------------------------------------------

# A pretend tmux. display-message answers for the one session that exists,
# with this test's own pid as the pane's process — a real, running pid whose
# start time /proc can confirm.
PANE_PID=$$
tmux() {
  case "$1" in
    display-message)
      case "$*" in
        *"=cx-api@impl:"*) printf '%s\t%s\t%s\n' "$PANE_PID" "$PROJ" "${CREATED:-100}" ;;
        *) return 1 ;;
      esac
      ;;
    *) return 0 ;;
  esac
}

proc_start() {
  local stat rest
  [ -r "/proc/$1/stat" ] || {
    printf '%s' -
    return 0
  }
  read -r stat <"/proc/$1/stat"
  rest="${stat##*) }"
  # shellcheck disable=SC2086
  set -- $rest
  printf '%s' "${20}"
}

# status_file PID STATUS [TMUX] [SID] [START] — Claude's per-process file.
status_file() {
  local start="${5:-$(proc_start "$1")}"
  printf '{"pid":%s,"sessionId":"%s","procStart":"%s","cwd":"%s","kind":"interactive","tmux":"%s","status":"%s"}\n' \
    "$1" "${4:-$SID}" "$start" "$PROJ" "${3:-cx-api@impl:@1.%1}" "$2" \
    >"$CX_CLAUDE_DIR/sessions/$1.json"
}

bar() { cmd_tmux_status "$@" 2>"$TMP/stderr"; }

describe "cx-agent tmux-status — run by tmux"

statusline "$(line_json)"
status_file "$PANE_PID" idle
: >"$TMP/transcript"
mkdir -p "$TMP/claude/projects/x"
: >"$TMP/claude/projects/x/$SID.jsonl"
out=$(bar api@impl)

it "shows the session's state, from Claude's own status file"
assert_contains "$out" "idle"

it "names the model, without the context size in brackets"
assert_contains "$out" "Opus 5"
assert_not_contains "$out" "(1M context)"

it "shows how full the context is"
assert_contains "$out" "ctx 8% 79k/1M"

it "shows the five-hour and weekly usage limits"
assert_contains "$out" "5h 9%"
assert_contains "$out" "7d 56%"

it "shows what the session has cost"
assert_contains "$out" '$1.23'

it "shows the lines it changed"
assert_contains "$out" "+12 -3"

it "puts nothing on stderr"
assert_eq "$(cat "$TMP/stderr")" ""

it "never prints a # that tmux would read as a format"
assert_not_contains "$out" "#"

status_file "$PANE_PID" waiting
it "shows a permission prompt as blocked"
assert_contains "$(bar api@impl)" "blocked"

status_file "$PANE_PID" busy
it "shows a turn in progress as working"
assert_contains "$(bar api@impl)" "working"

status_file "$PANE_PID" idle
it "draws the state with a plain shape by default"
assert_contains "$(bar api@impl)" "$(printf '\342\227\217') idle"

it "and with a Nerd Font icon when asked"
assert_contains "$(bar api@impl --icons nerd)" "$(printf '\357\201\230') idle"

rm -f "$TMP/claude/projects/x/$SID.jsonl"
it "calls an idle Claude with no conversation yet fresh"
assert_contains "$(bar api@impl)" "fresh"
: >"$TMP/claude/projects/x/$SID.jsonl"

describe "tmux-status degrades rather than failing"

it "prints nothing for a session that is not running"
assert_eq "$(bar nosuch)" ""

it "and exits 0"
bar nosuch >/dev/null
assert_eq "$?" 0

it "prints nothing with no slug at all"
assert_eq "$(bar)" ""

status_file "$PANE_PID" busy "" "$SID" 1
it "ignores a status file left by an earlier process under the same pid"
assert_not_contains "$(bar api@impl)" "working"
status_file "$PANE_PID" idle

printf '{"version":1,"sessions":{"api@impl":{"uuid":"%s"}}}\n' "$SID" >"$CX_SESSIONS"
rm -f "$CX_CLAUDE_DIR/sessions/$PANE_PID.json"
printf 'blocked\t%s\tPermissionRequest\twants to use Bash\n' "$(date +%s)" >"$CX_STATE_DIR/$SID"
out=$(bar api@impl)

it "falls back to the hook's report, found through the pin, with no status file"
assert_contains "$out" "blocked"

it "still shows what the status line reported"
assert_contains "$out" "ctx 8%"

printf 'blocked\t50\tPermissionRequest\told\n' >"$CX_STATE_DIR/$SID"
it "but not a report older than the tmux session it would describe"
assert_not_contains "$(bar api@impl)" "blocked"
rm -f "$CX_STATE_DIR/$SID"

describe "tmux-status for a session that never ran cx's status line"
#
# Started by an older cx, or by a Claude without --settings. The transcript
# still says which model answered last and how big its context was.

rm -f "$CX_STATE_DIR/$SID.line"
status_file "$PANE_PID" idle
TDIR="$CX_CLAUDE_DIR/projects/$(_session_dir_name "$PROJ")"
mkdir -p "$TDIR"
{
  printf '{"type":"user","isSidechain":false,"message":{"role":"user","content":"go"}}\n'
  printf '{"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-5","stop_reason":"end_turn","usage":{"input_tokens":32,"cache_creation_input_tokens":4008,"cache_read_input_tokens":75404,"output_tokens":9}}}\n'
  printf '{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-4-5","usage":{"input_tokens":5,"cache_read_input_tokens":1}}}\n'
  printf '{"type":"last-prompt"}\n'
  printf '{"type":"assistant","isSidechain":false,"message":{"mod'
} >"$TDIR/$SID.jsonl"
out=$(bar api@impl)

it "shows the main thread's model, not a subagent's"
assert_contains "$out" "opus-5"
assert_not_contains "$out" "haiku"

it "and the tokens its last turn carried, without a percentage it cannot know"
assert_contains "$out" "ctx 79k"
assert_not_contains "$out" "%"

it "reads past a half-written last line"
assert_contains "$out" "idle"

# ---------------------------------------------------------------------------

describe "tmux-status counts other sessions waiting on you"

statusline "$(line_json)"
sleep 30 &
OTHER=$!
status_file "$OTHER" waiting "cx-web@tests:@2.%2" "99999999-2222-3333-4444-555555555555"

it "names another cx session showing a permission prompt"
assert_contains "$(bar api@impl)" "web@tests"

status_file 999999 waiting "cx-dead:@3.%3" "88888888-2222-3333-4444-555555555555" 1
it "but not one whose Claude has exited"
assert_not_contains "$(bar api@impl)" "dead"

status_file "$OTHER" waiting "notcx:@2.%2" "99999999-2222-3333-4444-555555555555"
it "nor a Claude that cx did not start"
assert_not_contains "$(bar api@impl)" "notcx"

status_file "$PANE_PID" waiting
it "nor the session the bar is on"
assert_not_contains "$(bar api@impl)" "api@impl"

kill "$OTHER" 2>/dev/null
OTHER=""

# ---------------------------------------------------------------------------

describe "_open_status_bar — what open does to the session's tmux"

TMUX_LOG="$TMP/tmux.log"
tmux() {
  printf '%s\n' "$*" >>"$TMUX_LOG"
  case "$*" in
    "show-options -gv status-right") printf '%s\n' '"#{=21:pane_title}" %H:%M' ;;
  esac
  return 0
}
CX_AGENT_BIN=/srv/cx-agent
export CX_AGENT_BIN

rm -f "$TMUX_LOG"
_open_status_bar cx-api@impl api@impl unicode

it "sets the bar on that session alone, never globally, by pane target (invariant 8)"
assert_contains "$(cat "$TMUX_LOG")" "set-option -t =cx-api@impl: status-right"
assert_not_contains "$(grep set-option "$TMUX_LOG")" " -g"

it "draws it with tmux-status, for exactly this session"
assert_contains "$(cat "$TMUX_LOG")" "#('/srv/cx-agent' tmux-status 'api@impl')"

it "keeps what was already on the right, after it"
assert_contains "$(cat "$TMUX_LOG")" "tmux-status 'api@impl') \"#{=21:pane_title}\" %H:%M"

it "gives it room"
assert_contains "$(cat "$TMUX_LOG")" "status-right-length"

rm -f "$TMUX_LOG"
_open_status_bar cx-api@impl api@impl nerd
it "asks for Nerd Font icons when open was told to"
assert_contains "$(cat "$TMUX_LOG")" "tmux-status 'api@impl' --icons nerd"

rm -f "$TMUX_LOG"
_open_status_bar cx-api@impl api@impl off
it "takes the bar away again for --bar off"
assert_contains "$(cat "$TMUX_LOG")" "set-option -u -t =cx-api@impl: status-right"
assert_not_contains "$(cat "$TMUX_LOG")" "tmux-status"

summary
