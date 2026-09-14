#!/usr/bin/env bash
# Unit tests for `cx-agent event` — the command every hook cx installs runs,
# with Claude Code's hook JSON on stdin — and for the settings that install it.
#
# The caller is Claude, not a person, and that changes what "correct" means.
# Nothing may reach stdout, because Claude reads a hook's stdout as context or
# as a permission decision. The exit status is always 0, because a hook's exit
# status is an instruction. And the session id names a file, so it is input
# like any other.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-event.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export CX_DATA_DIR="$TMP/data" CX_CLAUDE_DIR="$TMP/claude"
export CX_REGISTRY="$TMP/data/projects.json" CX_SESSIONS="$TMP/data/sessions.json"
export CX_GOALS="$TMP/data/goals.json" CX_STATE_DIR="$TMP/data/state"
export CX_AGENT_NO_MAIN=1
mkdir -p "$CX_DATA_DIR"

# shellcheck source=../../server/cx-agent
. "$ROOT/server/cx-agent"
set +eu

if ! have jq; then
  describe "event"
  it "needs jq"
  skip "jq unavailable"
  summary
  exit $?
fi

printf '{"version":1,"sessions":{"api":{"uuid":"u-api"}}}\n' >"$CX_SESSIONS"

# hook JSON — feed one hook report to cmd_event, capturing stdout and status.
hook() {
  printf '%s' "$1" | cmd_event >"$TMP/stdout" 2>/dev/null
  _T_RC=$?
}
state() { cut -f1 "$CX_STATE_DIR/${1:-u-api}" 2>/dev/null; }

describe "cx-agent event — what each hook means"

it "records a finished turn as idle"
hook '{"session_id":"u-api","hook_event_name":"Stop"}'
assert_eq "$(state)" idle

it "records a prompt being submitted as working"
hook '{"session_id":"u-api","hook_event_name":"UserPromptSubmit","prompt":"go"}'
assert_eq "$(state)" working

it "records a tool call as working"
hook '{"session_id":"u-api","hook_event_name":"PreToolUse","tool_name":"Bash"}'
assert_eq "$(state)" working

it "records a permission request as blocked"
hook '{"session_id":"u-api","hook_event_name":"PermissionRequest","tool_name":"Bash"}'
assert_eq "$(state)" blocked

it "names the tool a permission request is for"
# A real PermissionRequest carries no message; the tool name is what there is.
assert_contains "$(cut -f4 "$CX_STATE_DIR/u-api")" "wants to use Bash"

it "records a permission_prompt notification as blocked"
hook '{"session_id":"u-api","hook_event_name":"Stop"}'
hook '{"session_id":"u-api","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'
assert_eq "$(state)" blocked

it "keeps the notification's message"
assert_contains "$(cut -f4 "$CX_STATE_DIR/u-api")" "permission to use Bash"

it "records an idle_prompt notification as idle"
hook '{"session_id":"u-api","hook_event_name":"Notification","notification_type":"idle_prompt"}'
assert_eq "$(state)" idle

it "ignores a notification that says nothing about state"
hook '{"session_id":"u-api","hook_event_name":"Notification","notification_type":"auth_success"}'
assert_eq "$(state)" idle

it "records a brand-new session as fresh"
hook '{"session_id":"u-new","hook_event_name":"SessionStart","source":"startup"}'
assert_eq "$(state u-new)" fresh

it "records a resumed session as idle"
hook '{"session_id":"u-new","hook_event_name":"SessionStart","source":"resume"}'
assert_eq "$(state u-new)" idle

it "leaves the state alone on a compaction, which can happen mid-turn"
hook '{"session_id":"u-new","hook_event_name":"PreToolUse"}'
hook '{"session_id":"u-new","hook_event_name":"SessionStart","source":"compact"}'
assert_eq "$(state u-new)" working

it "forgets the session when it ends"
hook '{"session_id":"u-new","hook_event_name":"SessionEnd","reason":"exit"}'
assert_fail test -e "$CX_STATE_DIR/u-new"

it "stamps each report with the time it arrived"
hook '{"session_id":"u-api","hook_event_name":"Stop"}'
_at=$(cut -f2 "$CX_STATE_DIR/u-api")
assert_ok test "$_at" -ge $(($(date +%s) - 5))

describe "cx-agent event — the rules for running inside Claude"

it "prints nothing on stdout"
# Claude adds a hook's stdout to the conversation, and reads it as a decision
# for PermissionRequest. A single stray line here would be a prompt injection.
hook '{"session_id":"u-api","hook_event_name":"PermissionRequest"}'
assert_eq "$(cat "$TMP/stdout")" ""

it "exits 0 for an ordinary report"
assert_eq "$_T_RC" 0

it "exits 0 for input that is not JSON at all"
hook 'this is not json'
assert_eq "$_T_RC" 0

it "exits 0 for an empty stdin"
hook ''
assert_eq "$_T_RC" 0

it "refuses a session id that would escape the state directory"
hook '{"session_id":"../../escaped","hook_event_name":"Stop"}'
assert_fail test -e "$TMP/data/escaped"

it "and still exits 0 doing it"
assert_eq "$_T_RC" 0

it "ignores a report with no session id"
hook '{"hook_event_name":"Stop"}'
set -- "$CX_STATE_DIR"/*
assert_eq "$#" 1

describe "cx-agent event — telling the human"

cat >"$TMP/notify" <<'EOF'
#!/bin/sh
printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$CX_NOTIFY_HOST" >>"$(dirname "$0")/notified"
EOF
chmod +x "$TMP/notify"
# Read by the sourced agent's _event_notify, not by this file.
# shellcheck disable=SC2034
CX_NOTIFY="$TMP/notify"
rm -f "$TMP/notified"

# notified N — wait up to two seconds for the backgrounded notifier's Nth line.
notified() {
  local i=0
  while [ $i -lt 20 ]; do
    [ "$(grep -c . "$TMP/notified" 2>/dev/null || echo 0)" -ge "$1" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  cat "$TMP/notified" 2>/dev/null
}

hook '{"session_id":"u-api","hook_event_name":"UserPromptSubmit"}'
hook '{"session_id":"u-api","hook_event_name":"Stop"}'

it "runs the notifier when a session starts waiting"
assert_contains "$(notified 1)" "api|idle|"

it "names the host, so one notifier can serve several servers"
assert_contains "$(notified 1)" "|$(hostname)"

it "does not run it again while the session goes on waiting"
hook '{"session_id":"u-api","hook_event_name":"Notification","notification_type":"idle_prompt"}'
sleep 0.5
assert_eq "$(grep -c . "$TMP/notified")" 1

it "runs it when the session needs a permission answer"
hook '{"session_id":"u-api","hook_event_name":"PermissionRequest"}'
assert_contains "$(notified 2)" "api|blocked|"

it "does not run it for working, which needs nobody"
hook '{"session_id":"u-api","hook_event_name":"PostToolUse"}'
sleep 0.5
assert_eq "$(grep -c . "$TMP/notified")" 2

it "stays silent for a conversation cx did not pin"
hook '{"session_id":"u-stranger","hook_event_name":"Stop"}'
sleep 0.5
assert_eq "$(grep -c . "$TMP/notified")" 2

it "does nothing, quietly, when there is no notifier"
# shellcheck disable=SC2034
CX_NOTIFY="$TMP/no-such-notifier"
hook '{"session_id":"u-api","hook_event_name":"UserPromptSubmit"}'
hook '{"session_id":"u-api","hook_event_name":"Stop"}'
assert_eq "$_T_RC" 0

describe "_hook_settings — what cx open hands Claude"

SETTINGS=$(_hook_settings "/opt/cx dir/cx-agent")

it "routes every event cx reads to cx-agent event"
assert_eq \
  "$(jq -r '.hooks | keys | sort | join(",")' <<<"$SETTINGS")" \
  "Notification,PermissionRequest,PostToolUse,PostToolUseFailure,PreToolUse,SessionEnd,SessionStart,Stop,UserPromptSubmit"

it "quotes the agent path for the shell Claude runs the hook in"
assert_eq "$(jq -r '.hooks.Stop[0].hooks[0].command' <<<"$SETTINGS")" "'/opt/cx dir/cx-agent' event"

it "bounds each hook with a timeout"
assert_eq "$(jq -r '.hooks.PreToolUse[0].hooks[0].timeout' <<<"$SETTINGS")" 10

it "sets nothing but hooks, so the user's own settings stand"
assert_eq "$(jq -r 'keys | join(",")' <<<"$SETTINGS")" hooks

summary
