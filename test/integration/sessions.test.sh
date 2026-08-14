#!/usr/bin/env bash
# Integration tests for session commands and cx ask.
#
# `cx open` attaches a terminal, which a test harness cannot do — so these
# drive the agent's open path directly (exactly what the client invokes) and
# assert on the resulting tmux state. That covers the logic that actually
# matters: creating once, not stacking a second Claude, and choosing the right
# Claude invocation per mode.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"
# shellcheck source=lib/nodes.sh
. "$ROOT/test/integration/lib/nodes.sh"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  describe "sessions integration"
  it "requires Docker"
  skip "docker unavailable"
  summary
  exit $?
fi

nodes_build || {
  describe "sessions integration"
  it "builds the node image"
  _t_no "$_T_NAME" "docker build failed"
  summary
  exit 1
}

HOME_DIR=$(nodes_env)
trap 'nodes_cleanup "$HOME_DIR"' EXIT

P1=$(nodes_start web1 "$HOME_DIR") || {
  describe "sessions integration"
  it "starts a node"
  _t_no "$_T_NAME" "failed"
  summary
  exit 1
}
nodes_add_host "$HOME_DIR" cx-test-web1 "$P1"
cx_run "$HOME_DIR" provision cx-test-web1 >/dev/null 2>&1
cx_run "$HOME_DIR" new cx-test-web1:api >/dev/null 2>&1
cx_run "$HOME_DIR" new cx-test-web1:web >/dev/null 2>&1

NODE="${CX_NODE_PREFIX}web1"
on_node() { docker exec "$NODE" su - cxuser -c "$1" 2>&1; }
agent() { on_node "\$HOME/.local/bin/cx-agent $1"; }

# ---------------------------------------------------------------------------

describe "cx status with nothing running"

_out=$(cx_run "$HOME_DIR" status)

it "says so plainly"
assert_contains "$_out" 'No live sessions'

it "suggests how to start one"
assert_contains "$_out" 'cx open'

# ---------------------------------------------------------------------------

describe "opening a project creates a session and starts Claude"

agent 'open api --mode continue' >/dev/null 2>&1
sleep 1

it "creates the tmux session"
assert_contains "$(on_node 'tmux has-session -t cx-api && echo yes || echo no')" 'yes'

it "names it with the cx- prefix so cx status can find it"
assert_contains "$(on_node 'tmux list-sessions -F "#{session_name}"')" 'cx-api'

# Not --continue: cx pins a conversation id per session, so the first open of
# a project with no history starts a new one with a known id. --continue would
# mean "whatever is newest in this directory", which is exactly what makes two
# parallel sessions collide.
it "starts Claude on a pinned session id, in the project directory"
assert_contains "$(on_node 'tmux capture-pane -pJ -t =cx-api:')" 'new session'

it "and does so in the project directory"
assert_contains "$(on_node 'tmux capture-pane -pJ -t =cx-api:')" 'in /home/cxuser/projects/api'

it "records the pin so the next open resumes the same conversation"
assert_contains "$(on_node 'cat ~/.local/share/cx/sessions.json')" '"api"'

# ---------------------------------------------------------------------------

describe "re-opening does not stack a second Claude"

# The property that makes cx open safe to run repeatedly. The naive
# implementation sends the claude command every time and you end up with
# Claude running inside Claude.
agent 'open api --mode continue' >/dev/null 2>&1
sleep 1

it "still has exactly one Claude invocation in the pane"
assert_eq "$(on_node 'tmux capture-pane -pJ -t =cx-api: | grep -c "STUB: new session"')" '1'

it "still has exactly one tmux session"
assert_eq "$(on_node 'tmux list-sessions | wc -l' | tr -d ' ')" '1'

# ---------------------------------------------------------------------------

describe "modes choose different Claude invocations"

agent 'open web --mode resume' >/dev/null 2>&1
sleep 1

it "resume mode starts the session picker, with no id pinned"
assert_contains "$(on_node 'tmux capture-pane -pJ -t =cx-web:')" 'resume picker'

on_node 'tmux kill-session -t =cx-web' >/dev/null 2>&1
agent 'open web --mode shell' >/dev/null 2>&1
sleep 1

it "shell mode starts no Claude at all"
assert_not_contains "$(on_node 'tmux capture-pane -pJ -t =cx-web:')" 'STUB'

it "but still creates the session"
assert_contains "$(on_node 'tmux has-session -t =cx-web && echo yes || echo no')" 'yes'

# ---------------------------------------------------------------------------

describe "named sessions run in parallel on one project"

# The feature in one block: several conversations on the same files, each
# reachable by name and each with its own history.
on_node 'tmux kill-server' >/dev/null 2>&1
agent 'open api --mode continue' >/dev/null 2>&1
agent 'open api --session review --mode continue' >/dev/null 2>&1
agent 'open api --session tests --mode continue' >/dev/null 2>&1
sleep 1

it "creates one tmux session per label"
assert_eq "$(on_node 'tmux list-sessions -F "#{session_name}" | sort | tr "\n" " "')" \
  'cx-api cx-api@review cx-api@tests '

it "pins a separate conversation id for each"
assert_eq "$(on_node 'jq -r ".sessions | keys | sort | join(\",\")" ~/.local/share/cx/sessions.json')" \
  'api,api@review,api@tests'

# Distinct ids are the entire point: equal ids would mean the three sessions
# share one conversation, which is the bug this feature exists to fix.
it "gives every session a DIFFERENT conversation id"
assert_eq "$(on_node 'jq -r "[.sessions[].uuid] | unique | length" ~/.local/share/cx/sessions.json')" '3'

it "runs all three in the same project directory"
assert_eq "$(on_node 'tmux capture-pane -pJ -t =cx-api@review: | grep -c "in /home/cxuser/projects/api"')" '1'

# tmux resolves a bare target as a prefix, so `-t cx-api` can land in
# cx-api@review. Everything cx does uses the exact-match "=" form.
it "reopening the default session does not attach to a labelled one"
_before=$(on_node 'tmux capture-pane -pJ -t =cx-api@review: | grep -c STUB')
agent 'open api --mode continue' >/dev/null 2>&1
sleep 1
assert_eq "$(on_node 'tmux capture-pane -pJ -t =cx-api@review: | grep -c STUB')" "$_before"

describe "a second open of a named session resumes its own conversation"

_uuid=$(on_node 'jq -r ".sessions[\"api@review\"].uuid" ~/.local/share/cx/sessions.json')
# Pretend Claude wrote history for that conversation: the store names each
# file after the session id it holds.
on_node "mkdir -p ~/.claude/projects/-home-cxuser-projects-api && \
         echo '{}' > ~/.claude/projects/-home-cxuser-projects-api/$_uuid.jsonl"
on_node 'tmux kill-session -t =cx-api@review' >/dev/null 2>&1
agent 'open api --session review --mode continue' >/dev/null 2>&1
sleep 1

it "resumes by id rather than starting a new conversation"
assert_contains "$(on_node 'tmux capture-pane -pJ -t =cx-api@review:')" "resuming session $_uuid"

it "keeps the same id it pinned the first time"
assert_eq "$(on_node 'jq -r ".sessions[\"api@review\"].uuid" ~/.local/share/cx/sessions.json')" "$_uuid"

describe "--dangerously-skip-permissions"

# The flag must reach exactly the session that asked for it and no other. A
# leak here hands someone an unguarded Claude they did not ask for.
agent 'open api --session yolo --dangerous --mode continue' >/dev/null 2>&1
sleep 1

it "passes the flag to the session that asked for it"
assert_contains "$(on_node 'tmux capture-pane -pJ -t "=cx-api@yolo:"')" 'STUB_NO_PERMISSIONS'

it "does not leak it into the project's other sessions"
assert_not_contains "$(on_node 'tmux capture-pane -pJ -t =cx-api:')" 'STUB_NO_PERMISSIONS'

it "records which mode that session was started with"
# The mode itself, not a boolean: --permission-mode acceptEdits and
# --dangerously-skip-permissions are both "not the default" and cx status has
# to be able to tell them apart.
assert_eq "$(on_node 'jq -r ".sessions[\"api@yolo\"].perm_mode" ~/.local/share/cx/sessions.json')" 'bypassPermissions'

# Absent, not empty: the default is never written, so this file stays a list
# of pins rather than growing an entry for every session ever opened.
it "and records nothing for the others"
assert_eq "$(on_node 'jq -r ".sessions[\"api\"].perm_mode // \"\"" ~/.local/share/cx/sessions.json')" ''

it "without creating a marker key for them"
assert_eq "$(on_node 'jq -r ".sessions[\"api\"] | has(\"perm_mode\")" ~/.local/share/cx/sessions.json')" 'false'

it "still pins that session its own conversation"
assert_ne "$(on_node 'jq -r ".sessions[\"api@yolo\"].uuid" ~/.local/share/cx/sessions.json')" \
  "$(on_node 'jq -r ".sessions[\"api\"].uuid" ~/.local/share/cx/sessions.json')"

_out=$(cx_run "$HOME_DIR" status)

it "cx status flags it, since it is invisible from inside the session"
assert_contains "$_out" 'no-perms'

it "with a MODE column to put it in"
assert_contains "$_out" 'MODE'

# Permission mode is fixed when the pane's claude launches, so reattaching
# cannot change it. Both directions have to say so rather than implying the
# flag took effect.
_out=$(agent 'open api --session yolo --mode continue' 2>&1)
it "warns when reattaching to an unguarded session without asking for it"
assert_contains "$_out" 'already running with ALL permission checks bypassed'

_out=$(agent 'open api --dangerous --mode continue' 2>&1)
it "says the flag cannot be applied to an already-running guarded session"
assert_contains "$_out" 'cannot be applied to a live session'

# A stale `true` would make cx status lie in the direction that matters.
on_node 'tmux kill-session -t "=cx-api@yolo"' >/dev/null 2>&1
agent 'open api --session yolo --mode continue' >/dev/null 2>&1
sleep 1

it "restarting without the flag clears the record"
assert_eq "$(on_node 'jq -r ".sessions[\"api@yolo\"] | has(\"perm_mode\")" ~/.local/share/cx/sessions.json')" 'false'

it "but keeps that session's pinned conversation"
assert_ne "$(on_node 'jq -r ".sessions[\"api@yolo\"].uuid // \"\"" ~/.local/share/cx/sessions.json')" ''

it "and the session really is guarded again"
assert_not_contains "$(on_node 'tmux capture-pane -pJ -t "=cx-api@yolo:"')" 'STUB_NO_PERMISSIONS'

_out=$(agent 'open api --session sh1 --dangerous --mode shell' 2>&1)
it "refuses the flag for a shell session, where no Claude is started"
assert_contains "$_out" 'starts no Claude, so Claude options have no effect'

describe "cx ask --dangerously-skip-permissions"

_out=$(cx_run "$HOME_DIR" ask cx-test-web1:api --dangerously-skip-permissions "what is 2+2?")

it "still answers"
assert_contains "$_out" 'STUB_ANSWER: what is 2+2?'

it "passes the flag through"
assert_contains "$_out" 'STUB_NO_PERMISSIONS'

it "warns that permissions were skipped"
assert_contains "$_out" 'ALL permission checks bypassed'

# cx ask is built to be piped, so the warning must not land in the answer.
_stdout=$(env HOME="$HOME_DIR" CX_HOME="$ROOT" \
  CX_CONFIG_DIR="$HOME_DIR/.config/cx" CX_CONFIG_FILE="$HOME_DIR/.config/cx/config" \
  CX_SSHD_DIR="$HOME_DIR/.config/cx/ssh.d" CX_CACHE_DIR="$HOME_DIR/.cache/cx" \
  CX_SSH_CONFIG="$HOME_DIR/.ssh/config" CX_ASSUME_YES=1 NO_COLOR=1 \
  bash "$ROOT/bin/cx" ask cx-test-web1:api --dangerously-skip-permissions "hi" 2>/dev/null)

it "keeps the warning off stdout so piped output stays clean"
assert_not_contains "$_stdout" 'ALL permission checks bypassed'

it "while the answer is still on stdout"
assert_contains "$_stdout" 'STUB_ANSWER: hi'

_out=$(cx_run "$HOME_DIR" shell cx-test-web1:api --dangerously-skip-permissions 2>&1)
it "cx shell rejects the flag rather than ignoring it"
assert_contains "$_out" 'starts no Claude, so Claude options have no effect'

on_node 'tmux kill-session -t "=cx-api@yolo"' >/dev/null 2>&1

# ---------------------------------------------------------------------------

describe "cx status names each session"

_out=$(cx_run "$HOME_DIR" status)

it "has a SESSION column"
assert_contains "$_out" 'SESSION'

it "shows the label of a named session"
assert_contains "$_out" 'review'

it "shows a dash for a project's default session"
assert_contains "$_out" '—'

describe "cx stop targets one session, not the project"

_out=$(cx_run "$HOME_DIR" stop cx-test-web1:api@review)

it "reports the labelled session stopped"
assert_contains "$_out" 'stopped cx-test-web1:api@review'

it "kills exactly that session"
assert_contains "$(on_node 'tmux has-session -t =cx-api@review 2>/dev/null && echo yes || echo no')" 'no'

it "and leaves the project's other sessions running"
assert_contains "$(on_node 'tmux has-session -t =cx-api 2>/dev/null && echo yes || echo no')" 'yes'

_out=$(cx_run "$HOME_DIR" stop cx-test-web1:api --all)

it "--all stops the rest"
assert_eq "$(on_node 'tmux list-sessions -F "#{session_name}" 2>/dev/null | grep -c "^cx-api" || true' | tr -d ' \r')" '0'

# Leave a plain session running: the blocks below are about the single-session
# behavior and expect the state this file started in.
agent 'open api --mode continue' >/dev/null 2>&1
sleep 1

# ---------------------------------------------------------------------------

describe "cx status reports live sessions"

_out=$(cx_run "$HOME_DIR" status)

it "lists a running project"
assert_contains "$_out" 'api'

it "reports whether anyone is attached"
assert_contains "$_out" 'detached'

it "attributes the session to its host"
assert_contains "$_out" 'cx-test-web1'

# ---------------------------------------------------------------------------

describe "cx ls marks live projects"

_out=$(cx_run "$HOME_DIR" -r ls)

it "shows the live marker"
assert_contains "$_out" '●'

# ---------------------------------------------------------------------------

describe "cx stop"

_out=$(cx_run "$HOME_DIR" stop cx-test-web1:api)

it "reports the session stopped"
assert_contains "$_out" 'stopped cx-test-web1:api'

it "actually kills the tmux session"
assert_contains "$(on_node 'tmux has-session -t cx-api 2>/dev/null && echo yes || echo no')" 'no'

_out=$(cx_run "$HOME_DIR" stop cx-test-web1:api)
it "stopping an already-stopped project is not an error"
assert_contains "$_out" 'no live session'

run_rc cx_run "$HOME_DIR" stop cx-test-web1:api
it "and exits 0"
assert_eq "$_T_RC" 0

# ---------------------------------------------------------------------------

describe "cx ask"

_out=$(cx_run "$HOME_DIR" ask cx-test-web1:api "what is 2+2?")

it "returns the answer on stdout"
assert_contains "$_out" 'STUB_ANSWER: what is 2+2?'

it "creates no tmux session"
assert_contains "$(on_node 'tmux has-session -t cx-api 2>/dev/null && echo yes || echo no')" 'no'

# The reason the prompt travels on stdin rather than argv.
_out=$(cx_run "$HOME_DIR" ask cx-test-web1:api 'what is $HOME and "quotes" and $(whoami)?')

it "passes shell metacharacters through untouched"
assert_contains "$_out" '$HOME and "quotes" and $(whoami)?'

_out=$(printf 'piped question' | cx_run "$HOME_DIR" ask cx-test-web1:api)

it "reads the prompt from stdin when none is given"
assert_contains "$_out" 'STUB_ANSWER: piped question'

_out=$(printf 'line one\nline two\n' | cx_run "$HOME_DIR" ask cx-test-web1:api)

it "handles a multi-line prompt"
assert_contains "$_out" 'line two'

_out=$(cx_run "$HOME_DIR" ask cx-test-web1:nosuchproject "hi" 2>&1)

it "reports an unknown project clearly"
assert_contains "$_out" 'no such project'

# ---------------------------------------------------------------------------

describe "completion targets"

cx_run "$HOME_DIR" ls >/dev/null 2>&1

it "writes a targets file"
assert_ok test -s "$HOME_DIR/.cache/cx/targets"

it "contains host:project pairs"
assert_contains "$(cat "$HOME_DIR/.cache/cx/targets")" 'cx-test-web1:api'

_out=$(CX_CACHE_DIR="$HOME_DIR/.cache/cx" CX_SSHD_DIR="$HOME_DIR/.config/cx/ssh.d" \
  bash -c '. "'"$ROOT"'/completions/cx.bash"
    COMP_WORDS=(cx open ""); COMP_CWORD=2; _cx; printf "%s" "${COMPREPLY[*]}"')

it "bash completion offers targets without touching the network"
assert_contains "$_out" 'cx-test-web1:api'

summary
