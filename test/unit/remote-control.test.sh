#!/usr/bin/env bash
# Unit tests for Remote Control: the session on claude.ai/code and in the
# Claude app that `cx open --remote-control` starts.
#
# Both halves, because the decision is split between them. The client knows
# the command line, the host file and CX_REMOTE_CONTROL; only the agent knows
# the project's own setting. So the client is pinned on what it sends, and the
# agent on what it does with that and its registry: the claude command line
# the pane gets, what is recorded, and what observe reports back.
#
# The facts these lean on were seen with Claude Code 2.1.306: the status file
# gains bridgeSessionId while Remote Control is on, and an RC session writes
# its transcript at startup, before any message.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-rc.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# The agent needs jq, and so does anything reading JSON. The rest must run
# where it is missing too: the bash 3.2 image has none, and bash 3.2 is the
# point of running there.
HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

# ===========================================================================
# The agent
# ===========================================================================
#
# In a subshell of its own, so that sourcing the agent cannot leave anything
# behind for the client half below.
# An `if`, not `[ ] && ( ) || FAILED_AGENT=1`: without jq that form takes the
# skipped half for a failed one.
if [ "$HAVE_JQ" = 1 ]; then (
  export CX_DATA_DIR="$TMP/data" CX_CLAUDE_DIR="$TMP/claude"
  export CX_REGISTRY="$TMP/data/projects.json" CX_SESSIONS="$TMP/data/sessions.json"
  export CX_GOALS="$TMP/data/goals.json" CX_STATE_DIR="$TMP/data/state"
  export CX_AGENT_NO_MAIN=1 CX_AGENT_BIN=/opt/cx-agent
  mkdir -p "$CX_DATA_DIR" "$TMP/api" "$TMP/web" "$TMP/bin"

  # shellcheck source=../../server/cx-agent
  . "$ROOT/server/cx-agent"
  set +eu

  cat >"$CX_REGISTRY" <<EOF
{"version":1,"root":"$TMP","projects":[
  {"name":"api","path":"$TMP/api"},
  {"name":"web","path":"$TMP/web","remote_control":false}]}
EOF

  # A Claude Code whose --help lists what the test says it has.
  CLAUDE_HELP="--session-id --resume --settings -n, --name --permission-mode --remote-control [name]"
  _find_claude() { printf '%s' "$TMP/bin/claude"; }
  write_claude() {
    printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$CLAUDE_HELP" >"$TMP/bin/claude"
    chmod +x "$TMP/bin/claude"
  }
  write_claude

  # tmux, recorded: no session exists until new-session makes one.
  tmux() {
    printf '%s\n' "$*" >>"$TMP/tmux.log"
    case "$1" in
      has-session) [ -e "$TMP/tmux.up" ] ;;
      new-session) : >"$TMP/tmux.up" ;;
      show-options) printf '' ;;
    esac
  }

  # open ARGS... — a detached cx-agent open of api@x from nothing, in a
  # subshell (die exits). Leaves the pane's command line in $TMP/launch.
  open() {
    rm -f "$TMP/tmux.log" "$TMP/tmux.up" "$TMP/launch"
    _CLAUDE_HELP=""
    (cmd_open api --session x --detach "$@") >"$TMP/open.json" 2>"$TMP/open.err"
    OPEN_RC=$?
    grep '^send-keys' "$TMP/tmux.log" 2>/dev/null >"$TMP/launch" || true
  }
  launch() { cat "$TMP/launch"; }

  describe "agent: _rc_resolve — the project's setting between the client's two"

  it "the command line wins over the project, both ways"
  assert_eq "$(_rc_resolve web on)$(_rc_resolve api off)" "10"

  it "a project with no setting follows the client's default"
  assert_eq "$(_rc_resolve api default-on)$(_rc_resolve api default-off)" "10"

  it "a project's own off beats a default of on"
  assert_eq "$(_rc_resolve web default-on)" "0"

  it "a project's own on beats a default of off"
  cmd_rc set api on >/dev/null
  assert_eq "$(_rc_resolve api default-off)" "1"
  cmd_rc set api default >/dev/null

  describe "agent: rc — the project's own setting"

  it "lists every project, null where there is no setting and false kept as false"
  assert_eq "$(cmd_rc ls | jq -c '[.projects[] | .remote_control]')" '[null,false]'

  it "sets it on, and reports what it set"
  assert_eq "$(cmd_rc set api on | jq -c .)" '{"name":"api","remote_control":true}'

  it "records it in the registry beside the project"
  assert_eq "$(jq -c '.projects[0].remote_control' "$CX_REGISTRY")" true

  it "default removes the key rather than storing a value"
  cmd_rc set api default >/dev/null
  assert_eq "$(jq -c '.projects[0] | has("remote_control")' "$CX_REGISTRY")" false

  it "refuses a project that does not exist, as not found"
  run_rc sh -c "CX_AGENT_NO_MAIN= bash '$ROOT/server/cx-agent' rc set nope on" </dev/null
  assert_eq "$_T_RC" 2

  it "refuses a value that is not on, off or default, as usage"
  run_rc sh -c "CX_AGENT_NO_MAIN= bash '$ROOT/server/cx-agent' rc set api yes"
  assert_eq "$_T_RC" 3

  describe "agent: open — the claude command line"

  it "passes --remote-control with the client's name when asked"
  open --rc on --rc-name "web1:api@x"
  assert_contains "$(launch)" "--remote-control 'web1:api@x'"

  it "keeps naming the session after its slug inside Claude"
  assert_contains "$(launch)" "--name 'api@x'"

  it "records it on the session's pin, with the name"
  assert_eq "$(jq -c '.sessions["api@x"] | [.remote_control, .rc_name]' "$CX_SESSIONS")" '[true,"web1:api@x"]'

  it "says so in its --detach answer"
  assert_eq "$(jq -c .remote_control "$TMP/open.json")" '{"enabled":true,"name":"web1:api@x"}'

  it "passes nothing when nothing turns it on, which is the argv older clients send"
  open
  assert_not_contains "$(launch)" "--remote-control"

  it "and clears the pin a previous session under that slug left"
  assert_eq "$(jq -c '.sessions["api@x"].remote_control // "gone"' "$CX_SESSIONS")" '"gone"'

  it "falls back to the slug when the client sent no name"
  open --rc on
  assert_contains "$(launch)" "--remote-control 'api@x'"

  it "turns it on for a project whose own setting is on, under a default of off"
  cmd_rc set api on >/dev/null
  open --rc default-off --rc-name "web1:api@x"
  assert_contains "$(launch)" "--remote-control 'web1:api@x'"

  it "but --rc off on the command line still wins"
  open --rc off --rc-name "web1:api@x"
  assert_not_contains "$(launch)" "--remote-control"
  cmd_rc set api default >/dev/null

  it "uses the client's default when the project has none"
  open --rc default-on --rc-name "web1:api@x"
  assert_contains "$(launch)" "--remote-control"

  it "refuses an explicit request on a Claude Code that lacks the flag, before any tmux"
  CLAUDE_HELP="--session-id --resume --settings"
  write_claude
  open --rc on
  assert_eq "$OPEN_RC:$(grep -c new-session "$TMP/tmux.log")" "1:0"

  it "but starts without it, and says so, when it only came from a default"
  open --rc default-on
  assert_eq "$OPEN_RC" 0
  assert_not_contains "$(launch)" "--remote-control"
  assert_contains "$(cat "$TMP/open.err")" "no Remote Control"
  CLAUDE_HELP="--session-id --resume --settings -n, --name --permission-mode --remote-control [name]"
  write_claude

  it "refuses --rc on for a shell, which starts no Claude"
  open --mode shell --rc on
  assert_eq "$OPEN_RC" 3

  it "refuses a name with a control character in it"
  open --rc on --rc-name "$(printf 'a\nb')"
  assert_eq "$OPEN_RC" 3

  it "warns about Remote Control together with no permission checks"
  open --rc on --dangerous
  assert_contains "$(cat "$TMP/open.err")" "anyone signed in"

  it "records Remote Control on resuming a conversation that had it, since Claude reconnects it"
  enc0() { printf '%s' "$1" | tr -c 'A-Za-z0-9-' '-'; }
  bdir="$CX_CLAUDE_DIR/projects/$(enc0 "$TMP/api")"
  mkdir -p "$bdir"
  bu=$(jq -r '.sessions["api@x"].uuid' "$CX_SESSIONS")
  printf '{"type":"bridge-session","bridgeSessionId":"cse_01X","sessionId":"%s"}\n' "$bu" >"$bdir/$bu.jsonl"
  open --rc off --rc-name "web1:api@x"
  assert_contains "$(launch)" "--resume"
  assert_eq "$(jq -c '.sessions["api@x"].remote_control' "$CX_SESSIONS")" true

  it "and says that --no-remote-control cannot take it away from that conversation"
  assert_contains "$(cat "$TMP/open.err")" "a new conversation"

  it "but does not pass --remote-control for it: Claude does that itself"
  assert_not_contains "$(launch)" "--remote-control"
  rm -f "$bdir/$bu.jsonl"

  it "tells a reattach that Remote Control cannot be added to a live session"
  open --rc off
  : >"$TMP/tmux.up"
  _CLAUDE_HELP=""
  (cmd_open api --session x --detach --rc on) >/dev/null 2>"$TMP/open.err"
  assert_contains "$(cat "$TMP/open.err")" "cx open --remote-control"

  describe "agent: observe — Remote Control, the mode, and an empty transcript"

  enc() { printf '%s' "$1" | tr -c 'A-Za-z0-9-' '-'; }
  sdir="$CX_CLAUDE_DIR/projects/$(enc "$TMP/api")"
  mkdir -p "$sdir" "$CX_CLAUDE_DIR/sessions"
  cat >"$CX_SESSIONS" <<'EOF'
{"version":1,"sessions":{
  "api@rc":    {"uuid":"u-rc", "remote_control":true, "rc_name":"web1:api@rc", "perm_mode":"bypassPermissions"},
  "api@plain": {"uuid":"u-plain"},
  "api@byhand":{"uuid":"u-hand"},
  "api@odd":   {"uuid":"u-odd"}}}
EOF
  # What an RC session leaves before anyone says anything: bookkeeping only.
  for u in u-rc u-hand u-odd; do
    {
      printf '{"type":"custom-title","customTitle":"api@rc","sessionId":"%s"}\n' "$u"
      printf '{"type":"bridge-session","bridgeSessionId":"session_01ABC","sessionId":"%s"}\n' "$u"
      printf '{"type":"system","isSidechain":false,"subtype":"init","sessionId":"%s"}\n' "$u"
    } >"$sdir/$u.jsonl"
  done
  {
    printf '{"type":"user","isSidechain":false,"message":{"role":"user","content":"go"}}\n'
    printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}\n'
  } >"$sdir/u-plain.jsonl"
  # Status files for live processes: this shell's pid is certainly running.
  status() {
    printf '{"pid":%s,"sessionId":"%s","status":"idle","kind":"interactive"%s}\n' \
      "$$" "$1" "${2:+,\"bridgeSessionId\":\"$2\"}" >"$CX_CLAUDE_DIR/sessions/$3.json"
  }
  status u-rc session_01RCabc 1
  status u-hand session_01Hand 2
  status u-odd 'x"/../evil' 3
  _tmux_rows() {
    printf 'cx-api@rc\t0\t1700000000\t1\t1700000100\tclaude\n'
    printf 'cx-api@plain\t0\t1700000000\t1\t1700000100\tclaude\n'
    printf 'cx-api@byhand\t0\t1700000000\t1\t1700000100\tclaude\n'
    printf 'cx-api@odd\t0\t1700000000\t1\t1700000100\tclaude\n'
  }
  OBS=$(cmd_observe --all --tail 0)
  obs() { printf '%s' "$OBS" | jq -c --arg t "$1" ".sessions[] | select(.target == \$t) | $2"; }

  it "reports the link from the bridge id of the running process"
  assert_eq "$(obs api@rc .remote_control.url)" '"https://claude.ai/code/session_01RCabc"'

  it "reports it enabled, with the name it was started under"
  assert_eq "$(obs api@rc '[.remote_control.enabled, .remote_control.name]')" '[true,"web1:api@rc"]'

  it "reports the permission mode recorded at creation"
  assert_eq "$(obs api@rc .perm_mode)" '"bypassPermissions"'

  it "reports a session without it as not enabled, with no link"
  assert_eq "$(obs api@plain .remote_control)" '{"enabled":false,"name":null,"url":null}'

  it "notices Remote Control turned on by hand inside a session cx started without it"
  assert_eq "$(obs api@byhand '[.remote_control.enabled, .remote_control.url]')" '[true,"https://claude.ai/code/session_01Hand"]'

  it "never makes a URL out of a bridge id of the wrong shape"
  assert_eq "$(obs api@odd .remote_control.url)" null

  it "calls a transcript with no message in it empty"
  assert_eq "$(obs api@rc .transcript.empty)" true

  it "and one with a conversation in it not empty"
  assert_eq "$(obs api@plain .transcript.empty)" false

  describe "agent: sessions — what cx status reads"

  it "says which sessions were started with Remote Control"
  assert_eq "$(cmd_sessions | jq -c '[.sessions[] | {(.target): .remote_control}] | add')" \
    '{"api@rc":true,"api@plain":false,"api@byhand":false,"api@odd":false}'

  summary
) || FAILED_AGENT=1; fi

# ===========================================================================
# The client
# ===========================================================================

export CX_HOME="$ROOT"
export CX_CONFIG_FILE="$TMP/no-such-config" CX_SSHD_DIR="$TMP/ssh.d" CX_CACHE_DIR="$TMP/cache"
mkdir -p "$CX_SSHD_DIR"
printf 'Host web1\n' >"$CX_SSHD_DIR/web1.conf"
printf '#cx:remote_control=1\nHost web2\n' >"$CX_SSHD_DIR/web2.conf"
printf '#cx:remote_control=0\nHost web3\n' >"$CX_SSHD_DIR/web3.conf"
printf '#cx:remote_control=yes\nHost web4\n' >"$CX_SSHD_DIR/web4.conf"

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
# shellcheck source=../../lib/cmd/rc.sh
. "$ROOT/lib/cmd/rc.sh"
# shellcheck source=../../lib/activity.sh
. "$ROOT/lib/activity.sh"

describe "client: _open_rc_args — what cx open tells the agent"

# rc_args HOST FLAG [CX_REMOTE_CONTROL] [AGENT_VERSION] — the argv, space-joined,
# then "|" and _OPEN_RC_WANT.
rc_args() {
  (
    # shellcheck disable=SC2034  # read by cx_target_str and _open_rc_args
    CX_T_HOST="$1" CX_T_PROJECT=api CX_T_WORKTREE="" CX_T_SESSION=x
    # shellcheck disable=SC2034
    CX_REMOTE_CONTROL="${3:-0}"
    _open_rc_args "${4:-0.8.0}" "$2" continue 2>/dev/null || exit $?
    printf '%s|%s' "${_OPEN_RC_ARGS[*]+${_OPEN_RC_ARGS[*]}}" "$_OPEN_RC_WANT"
  )
}

it "names the session after the full target, host alias included"
assert_eq "$(rc_args web1 on)" "--rc on --rc-name web1:api@x|1"

it "sends --no-remote-control as a decision"
assert_eq "$(rc_args web1 off 1)" "--rc off --rc-name web1:api@x|0"

it "sends CX_REMOTE_CONTROL as a default, which the project may override"
assert_eq "$(rc_args web1 "" 1)" "--rc default-on --rc-name web1:api@x|1"

it "sends default-off with nothing set, so the project can still turn it on"
assert_eq "$(rc_args web1 "")" "--rc default-off --rc-name web1:api@x|0"

it "takes the host file's line over CX_REMOTE_CONTROL, either way"
assert_eq "$(rc_args web2 "" 0)/$(rc_args web3 "" 1)" \
  "--rc default-on --rc-name web2:api@x|1/--rc default-off --rc-name web3:api@x|0"

it "refuses a host file line that is not 0 or 1, as a config error"
run_rc rc_args web4 ""
assert_eq "$_T_RC" 78

it "sends an agent older than 0.8.0 exactly the argv it always got"
assert_eq "$(rc_args web1 "" 1 0.7.0)" "|0"

it "refuses --remote-control against such an agent"
cx_agent() { return 0; }
run_rc rc_args web1 on 0 0.7.0
assert_eq "$_T_RC" 1

it "sends nothing for cx shell, which starts no Claude"
assert_eq "$(
  # shellcheck disable=SC2034  # read by _open_rc_args
  CX_T_HOST=web1 CX_T_PROJECT=api
  _open_rc_args 0.8.0 on shell
  printf '%s' "${_OPEN_RC_ARGS[*]+x}"
)" ""

describe "client: CX_REMOTE_CONTROL"

it "is refused, as a config error, when it is not 0 or 1"
run_rc env CX_REMOTE_CONTROL=yes bash -c ". '$ROOT/lib/config.sh'; cx_config_load"
assert_eq "$_T_RC" 78

describe "client: the classifier, for a transcript with no message in it"

st() { CX_IDLE_GRACE=120 cx_activity_state "$@"; }

it "calls a running RC session with Claude idle fresh, not idle"
assert_eq "$(st true false u1 empty "" "" 5 idle interactive "" true)" fresh

it "calls it fresh from the transcript alone, not working and then unknown"
assert_eq "$(st true false u1 empty "" "" 5)" fresh

it "does not call it starting: the file proves Claude got past startup"
assert_eq "$(st true false u1 empty "" "" 5 "" "" "" true)" fresh

it "still calls a hooked session with no file at all starting"
assert_eq "$(st true false u1 false "" "" "" "" "" "" true)" starting

it "lets cx nudge send to it, since fresh is steerable"
cx_activity_is_steerable fresh && _t_ok "$_T_NAME" || _t_no "$_T_NAME" "fresh not steerable"

if [ "$HAVE_JQ" = 1 ]; then
  it "reads empty from observe's JSON"
  printf '%s' '{"sessions":[{"target":"api@rc","tmux":{"alive":true,"shell":false,"attached":false,"created":1},"transcript":{"uuid":"u","present":true,"empty":true,"mtime":1},"claude":{"status":"idle","kind":"interactive"},"hooks":true,"last":null}]}' >"$TMP/obs.json"
  assert_eq "$(cx_activity_rows web1 "$TMP/obs.json" 10 | cut -f3)" fresh
fi

describe "client: cx rc"

cx_agent() {
  shift
  printf '%s\n' "$*" >>"$TMP/agent.log"
  case "$1 ${2:-}" in
    "version "*) printf '0.8.0\n' ;;
    "rc set") printf '{"name":"%s","remote_control":true}\n' "$3" ;;
    "rc ls") printf '{"projects":[{"name":"api","remote_control":null},{"name":"web","remote_control":false}]}\n' ;;
  esac
}
cx_cache_invalidate() { printf '%s\n' "$1" >>"$TMP/invalidated"; }

it "sets the project's setting through the agent"
rm -f "$TMP/agent.log"
cmd_rc on web1:api >/dev/null 2>&1
assert_contains "$(cat "$TMP/agent.log")" "rc set api on"

it "invalidates that host's cache, since cx ls reports the setting"
assert_eq "$(cat "$TMP/invalidated")" web1

it "refuses a worktree or a session, which have no setting of their own"
run_rc cmd_rc on web1:api/fix
assert_eq "$_T_RC" 3

if [ "$HAVE_JQ" = 1 ]; then
  it "lists what new sessions get, following the host's default where there is no setting"
  assert_eq "$(CX_JSON=1 cmd_rc web2 | jq -c '[.projects[] | .remote_control]')" '[true,false]'

  it "and a project's own off stays off under a host default of on"
  assert_eq "$(CX_JSON=1 cmd_rc web2 | jq -r '.projects[1].setting')" false
fi

summary
rc=$?
[ -z "${FAILED_AGENT:-}" ] || exit 1
exit "$rc"
