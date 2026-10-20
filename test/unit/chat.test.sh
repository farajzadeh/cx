#!/usr/bin/env bash
# Unit tests for `cx chat`: the agent's chat verb, the permission tool it hands
# Claude (chat-mcp), and the client half that runs it over ssh.
#
# Claude Code is a fake that replays stream-json recorded from a real one
# (test/fixtures/chat/, from the runs docs/chat.md describes). It does what the
# real one does on the wire: reads JSON lines on stdin, starts the permission
# tool from --mcp-config and speaks MCP to it, and calls it where the recording
# made a call — an approval, a question, and one it cancels, the way an
# interrupt does. Everything else runs for real: the agent is the repository's,
# run as its own process, in a HOME that is a temporary directory.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

if ! command -v jq >/dev/null 2>&1 || ! command -v mkfifo >/dev/null 2>&1; then
  describe "cx chat"
  it "needs jq and mkfifo"
  skip "unavailable"
  summary
  exit $?
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-chat.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)
trap 'exec 3>&- 2>/dev/null; rm -rf "$TMP"' EXIT
FIX="$ROOT/test/fixtures/chat"

export HOME="$TMP/home"
export CX_DATA_DIR="$TMP/data" CX_CLAUDE_DIR="$TMP/claude"
export CX_REGISTRY="$TMP/data/projects.json" CX_SESSIONS="$TMP/data/sessions.json"
export CX_GOALS="$TMP/data/goals.json" CX_STATE_DIR="$TMP/data/state"
export CX_CHAT_DIR="$TMP/data/chat" CX_NOTIFY="$TMP/no-notifier"
export TMPDIR="$TMP/tmp"
export FAKE_LOG="$TMP/claude.log" FAKE_FIX="$FIX" FAKE_DIR="$TMP/fake"
unset CX_AGENT_BIN TMUX
mkdir -p "$HOME/.local/bin" "$CX_DATA_DIR" "$CX_CLAUDE_DIR" "$TMPDIR" "$FAKE_DIR" "$TMP/api"
printf '{"version":1,"root":"%s","projects":[{"name":"api","path":"%s/api"}]}\n' "$TMP" "$TMP" >"$CX_REGISTRY"

# The agent puts $HOME/.local/bin first on its PATH, which is where Claude Code
# installs itself — so that is where the fakes go, and no real claude or tmux
# can be reached from here.
cat >"$HOME/.local/bin/tmux" <<'EOF'
#!/bin/sh
# Live sessions are the names listed in $FAKE_DIR/tmux-live.
case "$1" in
  has-session) grep -qx "${3#=}" "$FAKE_DIR/tmux-live" 2>/dev/null ;;
  *) exit 0 ;;
esac
EOF

cat >"$HOME/.local/bin/claude" <<'EOF'
#!/usr/bin/env bash
# A Claude Code that replays recorded stream-json. See the header of chat.test.sh.
set -u
{
  printf 'ARGS'
  for a in "$@"; do printf '\t%s' "$a"; done
  printf '\n'
} >>"$FAKE_LOG"
case " $* " in
  *" --help "*)
    printf '  --settings <file-or-json>\n  --effort <level>\n'
    exit 0
    ;;
esac
log() { printf '%s\n' "$*" >>"$FAKE_LOG"; }
sid="" mcp=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id | --resume)
      sid="$2"
      shift
      ;;
    --mcp-config)
      mcp="$2"
      shift
      ;;
    --append-system-prompt-file)
      cp "$2" "$FAKE_DIR/append.seen"
      shift
      ;;
  esac
  shift
done

# Start the permission tool the way Claude does, and do the handshake.
cmd=$(jq -r '.mcpServers.cx_chat.command' "$mcp")
a1=$(jq -r '.mcpServers.cx_chat.args[0]' "$mcp")
a2=$(jq -r '.mcpServers.cx_chat.args[1]' "$mcp")
mkfifo "$FAKE_DIR/mcp.in.$$" "$FAKE_DIR/mcp.out.$$"
"$cmd" "$a1" "$a2" <"$FAKE_DIR/mcp.in.$$" >"$FAKE_DIR/mcp.out.$$" &
exec 3>"$FAKE_DIR/mcp.in.$$" 4<"$FAKE_DIR/mcp.out.$$"
rm -f "$FAKE_DIR/mcp.in.$$" "$FAKE_DIR/mcp.out.$$"
rpc() { printf '%s\n' "$1" >&3; }
rpc '{"jsonrpc":"2.0","id":"server-discover-probe-1","method":"server/discover","params":{}}'
IFS= read -r resp <&4 && log "MCP $resp"
rpc '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"fake-claude","version":"0"}}}'
IFS= read -r resp <&4 && log "MCP $resp"
rpc '{"jsonrpc":"2.0","method":"notifications/initialized"}'
rpc '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
IFS= read -r resp <&4 && log "MCP $resp"
next=2

replay() {
  local l a decision="" msg="" id
  while IFS= read -r l; do
    case "$l" in
      '{"_mcp":'*)
        a=$(printf '%s' "$l" | jq -c '._mcp')
        id=$next
        next=$((next + 1))
        rpc "$(jq -nc --argjson a "$a" --argjson id "$id" \
          '{jsonrpc: "2.0", id: $id, method: "tools/call", params: {name: "permission", arguments: $a, _meta: {progressToken: $id}}}')"
        if [ "$(printf '%s' "$l" | jq -r '._cancel // false')" = true ]; then
          # What an interrupt does to a pending request: Claude stops waiting.
          while ! [ -e "$FAKE_DIR/cancel-now" ]; do sleep 0.1; done
          rm -f "$FAKE_DIR/cancel-now"
          rpc "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":$id,\"reason\":\"AbortError: remote-cancel\"}}"
          decision=cancelled
          continue
        fi
        IFS= read -r resp <&4
        log "DECISION $resp"
        decision=$(printf '%s' "$resp" | jq -r '.result.content[0].text | fromjson | .behavior')
        msg=$(printf '%s' "$resp" | jq -r '.result.content[0].text | fromjson | .message // ""')
        ;;
      '{"_when":'*)
        [ "$(printf '%s' "$l" | jq -r '._when')" = "$decision" ] || continue
        printf '%s\n' "$l" | jq -c --arg s "$sid" --arg m "$msg" \
          '.line | walk(if . == "__SID__" then $s elif . == "__MESSAGE__" then $m else . end)'
        ;;
      *) printf '%s\n' "${l//__SID__/$sid}" ;;
    esac
  done <"$FAKE_FIX/$1"
}

while IFS= read -r line; do
  log "STDIN $line"
  case "$(printf '%s' "$line" | jq -r '.type')" in
    user)
      text=$(printf '%s' "$line" | jq -r '.message.content | if type == "string" then . else (map(.text? // "") | join("")) end')
      case "$text" in
        crash) exit 3 ;;
        scenario:*) replay "${text#scenario:}.jsonl" ;;
        *) replay hello.jsonl ;;
      esac
      # The conversation now exists on disk, as Claude would leave it.
      d="$CX_CLAUDE_DIR/projects/$(printf '%s' "$PWD" | tr -c 'A-Za-z0-9-' '-')"
      mkdir -p "$d" && printf '{}\n' >>"$d/$sid.jsonl"
      ;;
    control_request)
      printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"still_queued":[]}}}\n' \
        "$(printf '%s' "$line" | jq -r '.request_id')"
      ;;
  esac
done
exec 3>&-
wait
exit 0
EOF
chmod +x "$HOME/.local/bin/claude" "$HOME/.local/bin/tmux"

# --- driving a chat ---------------------------------------------------------
#
# chat_start ARGS... — run `cx-agent chat api ARGS...` in the background, its
# stdin on fd 3 here, its stdout in $OUT and its exit status in $TMP/rc.
OUT="$TMP/out"
chat_start() {
  rm -f "$OUT" "$TMP/err" "$TMP/rc" "$TMP/in" "$FAKE_LOG"
  mkfifo "$TMP/in"
  (
    bash "$ROOT/server/cx-agent" chat "$@" <"$TMP/in" >"$OUT" 2>"$TMP/err"
    printf '%s' $? >"$TMP/rc"
  ) &
  exec 3>"$TMP/in"
}
send() { printf '%s\n' "$1" >&3; }
# wait_for JQ_FILTER — up to ten seconds for a stdout line the filter selects.
wait_for() {
  local i=0
  while [ $i -lt 100 ]; do
    [ -n "$(jq -c "select($1)" "$OUT" 2>/dev/null | head -1)" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
# chat_end — close stdin and wait for the exit status.
chat_end() {
  exec 3>&-
  local i=0
  while [ $i -lt 100 ] && [ ! -e "$TMP/rc" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  RC=$(cat "$TMP/rc" 2>/dev/null)
}
# out FILTER — the selected stdout lines, compact.
out() { jq -c "select($1)" "$OUT" 2>/dev/null; }
first() { head -1 "$OUT"; }
last() { tail -1 "$OUT"; }
pending_id() { out '.event == "permission_request"' | tail -1 | jq -r .id; }

describe "cx-agent chat — a conversation"

chat_start api
send '{"type":"user","message":{"role":"user","content":"hello"}}'
wait_for '.type == "result"'
chat_end

it "says ready first, with the conversation it pinned"
assert_eq "$(first | jq -r '[.type, .event, .target, .resumed] | join(" ")')" "cx ready api false"

it "pins the same conversation cx open would use"
UUID=$(jq -r '.sessions.api.uuid' "$CX_SESSIONS")
assert_eq "$(first | jq -r .session_id)" "$UUID"

it "names the directory it runs in"
assert_eq "$(first | jq -r .cwd)" "$TMP/api"

it "starts a new conversation with --session-id"
assert_contains "$(grep '^ARGS' "$FAKE_LOG")" "--session-id	$UUID"

it "passes Claude's lines through unchanged"
assert_eq "$(sed -n '2,$p' "$OUT" | sed '$d')" "$(sed "s/__SID__/$UUID/g" "$FIX/hello.jsonl")"

it "ends with exit, reason eof, code 0"
assert_eq "$(last | jq -c '[.event, .reason, .code]')" '["exit","eof",0]'

it "exits 0"
assert_eq "$RC" 0

it "streams partial messages, in stream-json both ways"
_args=$(grep '^ARGS' "$FAKE_LOG")
assert_contains "$_args" "--input-format	stream-json	--output-format	stream-json	--verbose	--include-partial-messages"

it "hands Claude its permission tool"
assert_contains "$_args" "--permission-prompt-tool	mcp__cx_chat__permission"

it "installs the hooks cx open installs"
assert_contains "$_args" '"PermissionRequest":[{"hooks":[{"type":"command","command":"'

it "installs no status line, which a headless Claude would never draw"
assert_not_contains "$_args" statusLine

it "lets go of the conversation and cleans up"
assert_eq "$(
  ls "$CX_CHAT_DIR" 2>/dev/null
  ls "$TMPDIR"
)" ""

chat_start api --model haiku --permission-mode acceptEdits --allowed-tools 'Read,Bash(npm test:*)'
send '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hello again"}]}}'
wait_for '.type == "result"'
chat_end

it "resumes the conversation the second time"
assert_eq "$(first | jq -r '[.session_id, .resumed] | join(" ")')" "$UUID true"

it "...with --resume"
assert_contains "$(grep '^ARGS' "$FAKE_LOG")" "--resume	$UUID"

it "passes the model, permission mode and allowed tools to Claude as argv"
_args=$(grep '^ARGS' "$FAKE_LOG")
assert_contains "$_args" "--permission-mode	acceptEdits	--model	haiku	--allowedTools	Read,Bash(npm test:*)"

it "accepts content blocks as well as a string"
assert_eq "$(out '.type == "result"' | wc -l | tr -d ' ')" 1

chat_start api --permission-mode default
chat_end
it "treats --permission-mode default as Claude's own default"
assert_not_contains "$(grep '^ARGS' "$FAKE_LOG")" "--permission-mode"

describe "cx-agent chat — approvals"

chat_start api
send '{"type":"user","message":{"role":"user","content":"scenario:approval"}}'
wait_for '.event == "permission_request"'
REQ=$(out '.event == "permission_request"')

it "asks the client before the tool runs"
assert_eq "$(printf '%s' "$REQ" | jq -r '[.tool_name, .tool_use_id, .input.command] | join(" ")')" \
  "Bash toolu_01Y6LXMQb5QxM63WLj16UrTU echo one > c.txt"

it "gives the request an id the client can answer"
assert_contains "$(printf '%s' "$REQ" | jq -r .id)" "p"

it "keeps the turn waiting until the answer comes"
sleep 0.3
assert_eq "$(out '.type == "result"')" ""

send "{\"type\":\"cx\",\"op\":\"permission\",\"id\":\"$(pending_id)\",\"behavior\":\"allow\"}"
wait_for '.type == "result"'

it "lets the tool run once allowed"
assert_eq "$(out '.type == "user"' | jq -r '.message.content[0].is_error')" false

it "tells Claude allow, with the original input when the client sent none"
_dec=$(grep '^DECISION' "$FAKE_LOG" | sed 's/^DECISION //' | jq -c '.result.content[0].text | fromjson')
assert_eq "$_dec" '{"behavior":"allow","updatedInput":{"command":"echo one > c.txt","description":"Write \"one\" to c.txt"}}'

send '{"type":"user","message":{"role":"user","content":"scenario:approval"}}'
wait_for '(.event == "permission_request") and (.id != "'"$(printf '%s' "$REQ" | jq -r .id)"'")'
send "{\"type\":\"cx\",\"op\":\"permission\",\"id\":\"$(pending_id)\",\"behavior\":\"allow\",\"updatedInput\":{\"command\":\"echo two > c.txt\"}}"
i=0
while [ "$(out '.type == "result"' | wc -l | tr -d ' ')" -lt 2 ] && [ $i -lt 100 ]; do
  sleep 0.1
  i=$((i + 1))
done

it "replaces the input with the client's updatedInput"
_dec=$(grep '^DECISION' "$FAKE_LOG" | tail -1 | sed 's/^DECISION //' | jq -c '.result.content[0].text | fromjson')
assert_eq "$_dec" '{"behavior":"allow","updatedInput":{"command":"echo two > c.txt"}}'

send '{"type":"user","message":{"role":"user","content":"scenario:approval"}}'
sleep 0.5
_n=$(out '.event == "permission_request"' | wc -l | tr -d ' ')
i=0
while [ "$_n" -lt 3 ] && [ $i -lt 50 ]; do
  sleep 0.1
  _n=$(out '.event == "permission_request"' | wc -l | tr -d ' ')
  i=$((i + 1))
done
send "{\"type\":\"cx\",\"op\":\"permission\",\"id\":\"$(pending_id)\",\"behavior\":\"deny\",\"message\":\"Not on a Friday.\"}"
i=0
while [ "$(out '.type == "result"' | wc -l | tr -d ' ')" -lt 3 ] && [ $i -lt 100 ]; do
  sleep 0.1
  i=$((i + 1))
done

it "tells Claude deny, with the client's message"
_dec=$(grep '^DECISION' "$FAKE_LOG" | tail -1 | sed 's/^DECISION //' | jq -c '.result.content[0].text | fromjson')
assert_eq "$_dec" '{"behavior":"deny","message":"Not on a Friday."}'

it "and Claude sees that message as the tool's result"
assert_eq "$(out '.type == "user"' | tail -1 | jq -r '.message.content[0] | [.is_error, .content] | map(tostring) | join(" ")')" \
  "true Not on a Friday."

it "complains about an answer to a request that is not pending"
send '{"type":"cx","op":"permission","id":"p1-99","behavior":"allow"}'
wait_for '.event == "error"'
assert_eq "$(out '.event == "error"' | jq -r .message)" "no pending request with id p1-99"

chat_end
it "exits 0 after all that"
assert_eq "$RC" 0

describe "cx-agent chat — questions (AskUserQuestion)"

chat_start api
send '{"type":"user","message":{"role":"user","content":"scenario:question"}}'
wait_for '.event == "permission_request"'
REQ=$(out '.event == "permission_request"')

it "arrives as a permission request for AskUserQuestion, questions in input"
assert_eq "$(printf '%s' "$REQ" | jq -r '[.tool_name, .input.questions[0].question, (.input.questions[0].options | map(.label) | join("/"))] | join(" | ")')" \
  "AskUserQuestion | Which color do you prefer? | Red/Green/Blue"

send "{\"type\":\"cx\",\"op\":\"permission\",\"id\":\"$(pending_id)\",\"behavior\":\"allow\",\"updatedInput\":{\"answers\":{\"Which color do you prefer?\":\"Green\"}}}"
wait_for '.type == "result"'

it "lays answers over the original input, so the questions stay"
_dec=$(grep '^DECISION' "$FAKE_LOG" | tail -1 | sed 's/^DECISION //' | jq -c '.result.content[0].text | fromjson')
assert_eq "$(printf '%s' "$_dec" | jq -c '[.behavior, (.updatedInput.questions | length), .updatedInput.answers]')" \
  '["allow",1,{"Which color do you prefer?":"Green"}]'

it "and the turn finishes with Claude's own answer"
assert_eq "$(out '.type == "result"' | jq -r .result)" "You picked Green."
chat_end

describe "cx-agent chat — interrupts and cancellations"

chat_start api
send '{"type":"user","message":{"role":"user","content":"scenario:cancel"}}'
wait_for '.event == "permission_request"'
_cid=$(pending_id)
send '{"type":"cx","op":"interrupt"}'
# The interrupt is what makes Claude give up on the request. The fake reads its
# stdin only between turns, so it is told to give up here instead.
: >"$FAKE_DIR/cancel-now"
wait_for '.event == "permission_cancelled"'
wait_for '.type == "control_response"'

it "sends Claude an interrupt as its own control request"
assert_contains "$(grep '^STDIN' "$FAKE_LOG")" '"request":{"subtype":"interrupt"}'

it "passes Claude's control response through"
assert_eq "$(out '.type == "control_response"' | jq -r .response.subtype)" success

it "says when Claude stops waiting for an answer"
assert_eq "$(out '.event == "permission_cancelled"' | jq -r .id)" "$_cid"

it "and that request can no longer be answered"
send "{\"type\":\"cx\",\"op\":\"permission\",\"id\":\"$_cid\",\"behavior\":\"allow\"}"
wait_for '.event == "error"'
assert_eq "$(out '.event == "error"' | jq -r .message)" "no pending request with id $_cid"

it "carries on with the conversation"
wait_for '.type == "result"'
send '{"type":"user","message":{"role":"user","content":"hello"}}'
i=0
while [ "$(out '.type == "result"' | wc -l | tr -d ' ')" -lt 2 ] && [ $i -lt 100 ]; do
  sleep 0.1
  i=$((i + 1))
done
assert_eq "$(out '.type == "result"' | wc -l | tr -d ' ')" 2
chat_end

describe "cx-agent chat — how it ends"

chat_start api
send '{"type":"user","message":{"role":"user","content":"hello"}}'
send '{"type":"cx","op":"close"}'
send '{"type":"user","message":{"role":"user","content":"never read"}}'
chat_end
it "ends on op close, after the turn, with reason close"
assert_eq "$(last | jq -c '[.event, .reason, .code]')" '["exit","close",0]'
it "and reads nothing after it"
assert_not_contains "$(cat "$FAKE_LOG")" "never read"

chat_start api
send '{"type":"user","message":{"role":"user","content":"scenario:approval"}}'
wait_for '.event == "permission_request"'
chat_end
it "denies what is still pending when the client goes"
_dec=$(grep '^DECISION' "$FAKE_LOG" | tail -1 | sed 's/^DECISION //' | jq -c '.result.content[0].text | fromjson')
assert_eq "$_dec" '{"behavior":"deny","message":"The chat was closed before this was answered."}'
it "...so the turn can finish, and the chat exits with reason eof"
assert_eq "$(last | jq -c '[.event, .reason]')" '["exit","eof"]'

chat_start api
send '{"type":"user","message":{"role":"user","content":"crash"}}'
wait_for '.event == "exit"'
chat_end
it "reports Claude exiting by itself as claude_exited, code 1"
assert_eq "$(last | jq -c '[.event, .reason, .code]')" '["exit","claude_exited",1]'
it "...and exits 1"
assert_eq "$RC" 1

describe "cx-agent chat — what the client may send"

chat_start api
send 'not json'
send '{"type":"cx","op":"dance"}'
send '{"type":"control_request","request_id":"x","request":{"subtype":"set_permission_mode","mode":"bypassPermissions"}}'
send '{"type":"cx","op":"permission","id":"../../etc","behavior":"allow"}'
wait_for '.event == "error" and (.message | test("id of a pending"))'
chat_end
it "answers an unknown op with the contract's error"
assert_contains "$(out '.event == "error"' | jq -r .message)" "unknown op"
it "refuses a line that is not JSON"
assert_contains "$(out '.event == "error"' | jq -r .message)" "not a JSON object"
it "does not pass Claude's control protocol through from the client"
assert_not_contains "$(grep '^STDIN' "$FAKE_LOG")" set_permission_mode
it "refuses an id that could name a path"
assert_contains "$(out '.event == "error"' | jq -r .message)" "op permission needs the id of a pending request"

describe "cx-agent chat — the system prompt travels on stdin"

printf 'Be brief.\nAnd kind: $(no) `shell` here.\n' >"$TMP/sys.md"
chat_start api --system-prompt-stdin
send "$(jq -Rsc '{type: "cx", op: "system_prompt", append: .}' <"$TMP/sys.md")"
chat_end
it "reaches Claude as --append-system-prompt-file, byte for byte"
assert_eq "$(cat "$FAKE_DIR/append.seen" 2>/dev/null)" "$(cat "$TMP/sys.md")"

chat_start api --system-prompt-stdin
send '{"type":"user","message":{"role":"user","content":"hello"}}'
chat_end
it "is a usage error when the first line is something else"
assert_eq "$RC:$(last | jq -r .code)" "3:3"

describe "cx-agent chat — one conversation, one writer"

printf 'cx-api\n' >"$FAKE_DIR/tmux-live"
chat_start api
chat_end
it "refuses a conversation a live tmux session holds"
assert_eq "$(first)" '{"type":"cx","event":"refused","reason":"live"}'
it "...exits 4"
assert_eq "$RC" 4
it "...and still ends with exit"
assert_eq "$(last | jq -c '[.event, .code]')" '["exit",4]'
rm -f "$FAKE_DIR/tmux-live"

# On a labelled session: cx ask with no label starts a conversation of its own,
# so only a label's conversation can have two writers through ask.
chat_start api --session rev
send '{"type":"user","message":{"role":"user","content":"scenario:approval"}}'
wait_for '.event == "permission_request"'
REV=$(jq -r '.sessions["api@rev"].uuid' "$CX_SESSIONS")

it "holds the conversation while it runs"
assert_ok test -r "$CX_CHAT_DIR/$REV/owner"

it "is reported by observe as a chat, with what is pending"
_obs=$(bash "$ROOT/server/cx-agent" observe api --session rev 2>/dev/null)
assert_eq "$(printf '%s' "$_obs" | jq -c '.sessions[0].chat | {pending}')" '{"pending":1}'

it "...which cx peek and cx bar read as blocked"
# shellcheck source=../../lib/activity.sh
. "$ROOT/lib/activity.sh"
printf '%s' "$_obs" >"$TMP/obs.json"
assert_eq "$(cx_activity_rows web1 "$TMP/obs.json" "$(date +%s)" | cut -f3)" blocked

it "refuses a second chat on it"
_second=$(bash "$ROOT/server/cx-agent" chat api --session rev </dev/null 2>/dev/null)
assert_eq "$(printf '%s\n' "$_second" | head -1)" '{"type":"cx","event":"refused","reason":"chat"}'

it "refuses cx open, which would start a second writer"
run_rc bash "$ROOT/server/cx-agent" open api --session rev --mode continue --detach
assert_eq "$_T_RC" 4

it "refuses cx ask on it"
_T_RC=0
printf 'hi' | bash "$ROOT/server/cx-agent" ask api --session rev >/dev/null 2>&1 || _T_RC=$?
assert_eq "$_T_RC" 4

it "refuses cx forget on it"
run_rc bash "$ROOT/server/cx-agent" forget api --session rev
assert_eq "$_T_RC" 4

chat_end

it "lets go of it once the chat is over"
assert_fail test -e "$CX_CHAT_DIR/$REV"

it "takes over a claim whose process is gone"
mkdir -p "$CX_CHAT_DIR/$UUID"
printf '999999\t-\t/nowhere\tapi\n' >"$CX_CHAT_DIR/$UUID/owner"
chat_start api
chat_end
assert_eq "$(first | jq -r .event)" ready

describe "cx-agent chat — refusing what it cannot do"

run_rc bash "$ROOT/server/cx-agent" chat
it "is a usage error without a project"
assert_eq "$_T_RC" 3

_o=$(bash "$ROOT/server/cx-agent" chat nope </dev/null 2>/dev/null)
it "is not found for an unknown project, with an exit line"
assert_eq "$(printf '%s\n' "$_o" | tail -1 | jq -c '[.event, .code, .reason]')" '["exit",2,"error"]'

_o=$(bash "$ROOT/server/cx-agent" chat api --permission-mode sometimes </dev/null 2>/dev/null)
it "refuses an unknown permission mode"
assert_eq "$(printf '%s\n' "$_o" | tail -1 | jq -r .code)" 3

_o=$(bash "$ROOT/server/cx-agent" chat api --session 'a.b' </dev/null 2>/dev/null)
it "refuses a label tmux would mangle"
assert_eq "$(printf '%s\n' "$_o" | tail -1 | jq -r .code)" 3

describe "cx-agent chat-mcp — the permission tool, alone"

it "does nothing for a directory a chat did not make"
_o=$(printf '%s\n' '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}' |
  bash "$ROOT/server/cx-agent" chat-mcp "$TMP" 2>/dev/null)
assert_eq "$_o" ""

describe "cx_activity_state — a chat has no tmux"

it "is blocked while a request waits for the client"
assert_eq "$(cx_activity_state false false u true assistant tool_use 5 busy interactive working true 1)" blocked
it "is working while Claude says busy"
assert_eq "$(cx_activity_state false false u true assistant tool_use 5 busy interactive "" true 0)" working
it "is idle when Claude says idle"
assert_eq "$(cx_activity_state false false u true assistant end_turn 5 idle interactive "" true 0)" idle
it "falls back to what the hooks said"
assert_eq "$(cx_activity_state false false u true "" "" "" "" "" working true 0)" working
it "is fresh before its first turn"
assert_eq "$(cx_activity_state false false u false "" "" "" "" "" "" true 0)" fresh
it "is still dead without a chat"
assert_eq "$(cx_activity_state false false u true assistant end_turn 5 idle interactive "" true)" dead

describe "cx chat — the client half"

export CX_HOME="$ROOT" CX_CACHE_DIR="$TMP/cache" CX_SSHD_DIR="$TMP/ssh.d"
export CX_CONFIG_FILE="$TMP/no-such-config"
mkdir -p "$CX_SSHD_DIR"
printf 'Host web1\n' >"$CX_SSHD_DIR/web1.conf"
# shellcheck source=../../lib/compat.sh
. "$ROOT/lib/compat.sh"
# shellcheck source=../../lib/config.sh
. "$ROOT/lib/config.sh"
# shellcheck source=../../lib/ui.sh
. "$ROOT/lib/ui.sh"
# shellcheck source=../../lib/cache.sh
. "$ROOT/lib/cache.sh"
cx_config_load
# shellcheck source=../../lib/cmd/chat.sh
. "$ROOT/lib/cmd/chat.sh"

# ssh, played by the agent itself: the remote command line is split the way
# the far side's shell would split it, which is what makes the quoting real.
SSH_FAIL=0
cx_agent() { [ "$2" = version ] && printf '%s\n' "$CX_AGENT_VERSION_EXPECTED"; }
ssh() {
  local remote=""
  while [ $# -gt 0 ]; do
    remote="$1"
    shift
  done
  printf '%s\n' "$remote" >"$TMP/remote"
  [ "$SSH_FAIL" = 1 ] && return 255
  eval "set -- ${remote#"$CX_AGENT_PATH"}"
  bash "$ROOT/server/cx-agent" "$@"
}

_o=$(printf '%s\n' '{"type":"user","message":{"role":"user","content":"hello"}}' | cmd_chat web1:api 2>/dev/null)
_rc=$?
it "gives the ready line the full target, host included"
assert_eq "$(printf '%s\n' "$_o" | head -1 | jq -r '[.event, .target] | join(" ")')" "ready web1:api"
it "passes everything else through, ending with exit"
assert_eq "$(printf '%s\n' "$_o" | tail -1 | jq -c '[.event, .reason]')" '["exit","eof"]'
it "exits with the agent's status"
assert_eq "$_rc" 0
it "runs the agent's chat verb, every argument quoted"
assert_eq "$(cat "$TMP/remote")" "\$HOME/.local/bin/cx-agent 'chat' 'api'"

_o=$(printf '' | cmd_chat web1:api@review --model 'opus' --allowed-tools "Bash(git log:*),Read" 2>/dev/null)
it "sends the label, the model and the allowed tools as separate words"
assert_eq "$(cat "$TMP/remote")" "\$HOME/.local/bin/cx-agent 'chat' 'api' '--session' 'review' '--model' 'opus' '--allowed-tools' 'Bash(git log:*),Read'"

: >"$FAKE_DIR/append.seen"
printf "It's \$(fine).\n" >"$TMP/sys2.md"
_o=$(printf '' | cmd_chat web1:api --append-system-prompt-file "$TMP/sys2.md" 2>/dev/null)
it "sends the system prompt file's text over stdin, never as an argument"
assert_eq "$(cat "$FAKE_DIR/append.seen")" "$(cat "$TMP/sys2.md")"
assert_not_contains "$(cat "$TMP/remote")" "fine" "...and no word of it is on the command line"

_o=$(cmd_chat </dev/null 2>/dev/null)
_rc=$?
it "is a usage error without a target, and still ends with exit"
assert_eq "$_rc:$(printf '%s\n' "$_o" | tail -1 | jq -c '[.event, .code]')" '3:["exit",3]'

_o=$(cmd_chat web1:api --append-system-prompt-file "$TMP/no-such" </dev/null 2>/dev/null)
_rc=$?
it "refuses a system prompt file it cannot read"
assert_eq "$_rc" 3

SSH_FAIL=1
_o=$(cmd_chat web1:api </dev/null 2>/dev/null)
_rc=$?
SSH_FAIL=0
it "writes the exit line itself when ssh fails"
assert_eq "$_rc:$(printf '%s\n' "$_o" | tail -1 | jq -c '[.event, .code, .reason]')" '255:["exit",255,"error"]'

summary
