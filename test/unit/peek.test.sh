#!/usr/bin/env bash
# Unit tests for the client half of `cx peek`: what it asks the agent for, and
# how it turns the answer into the JSON a driver reads.
#
# The agent is stubbed, and the stub can pretend to be one that predates
# --unit. Both matter: narrowing on the server is what makes a peek at one
# session cheap, and an older agent must still get a correct answer.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

export CX_HOME="$ROOT"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-peek.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export CX_CACHE_DIR="$TMP/cache" CX_SSHD_DIR="$TMP/ssh.d"
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
# shellcheck source=../../lib/cmd/peek.sh
. "$ROOT/lib/cmd/peek.sh"

if ! cx_have jq; then
  describe "cx peek"
  it "needs jq"
  skip "jq unavailable"
  summary
  exit $?
fi

NOW=$(cx_now)
PAYLOAD=$(
  cat <<EOF
{"sessions":[
 {"target":"api","tmux":{"alive":true,"attached":false,"shell":false,"created":$((NOW - 900))},
  "transcript":{"uuid":"u1","present":true,"mtime":$((NOW - 60))},
  "last":{"role":"assistant","stop_reason":"end_turn"},"tail":[]},
 {"target":"api@review","tmux":{"alive":true,"attached":true,"shell":false,"created":$((NOW - 900))},
  "transcript":{"uuid":"u2","present":true,"mtime":$((NOW - 3000))},
  "last":{"role":"assistant","stop_reason":"tool_use"},"tail":[]},
 {"target":"api/authfix","tmux":{"alive":false,"attached":false,"shell":false,"created":null},
  "transcript":{"uuid":"u3","present":true,"mtime":$((NOW - 99))},
  "last":null,"tail":[]},
 {"target":"web","tmux":{"alive":true,"attached":false,"shell":false,"created":$((NOW - 30))},
  "transcript":{"uuid":"u4","present":true,"mtime":$((NOW - 5))},
  "last":{"role":"assistant","stop_reason":"tool_use"},"tail":[]}
]}
EOF
)

OLD_AGENT=0
# Stubbed after peek.sh, which pulls in lib/remote.sh and would otherwise
# define the real cx_agent over the top. Every call is logged, one per line.
GOAL='{"name":"ship","state":"active","members":["api@review","api/authfix","web2:dash"]}'
cx_agent() {
  local host="$1"
  shift
  printf '%s\n' "$*" >>"$TMP/agent.log"
  printf '%s %s\n' "$host" "$*" >>"$TMP/agent-hosts.log"
  case " $* " in
    " version ")
      printf '0.4.0\n'
      return 0
      ;;
    *" goal show ship "*)
      printf '%s' "$GOAL"
      return 0
      ;;
    *" goal show "*) return 2 ;;
    *" --unit "* | *" --slug "*)
      [ "$OLD_AGENT" = 1 ] && return 3
      ;;
  esac
  printf '%s' "$PAYLOAD"
}

peek_json() {
  rm -f "$TMP/agent.log"
  CX_JSON=1 cmd_peek "$@" 2>/dev/null
}
state_of() { jq -r --arg t "$2" '.sessions[] | select(.target == $t) | .'"$3" <<<"$1"; }

describe "cx peek --json — the driver's view"

OUT=$(peek_json)

it "reports every session"
assert_eq "$(jq '.sessions | length' <<<"$OUT")" 4

it "classifies a finished turn as idle"
assert_eq "$(state_of "$OUT" api state)" idle

it "classifies a quiet unfinished turn as blocked"
assert_eq "$(state_of "$OUT" api@review state)" blocked

it "classifies a moving turn as working"
assert_eq "$(state_of "$OUT" web state)" working

it "classifies a session with no tmux as dead"
assert_eq "$(state_of "$OUT" api/authfix state)" dead

it "marks only a ready session steerable"
assert_eq "$(jq -r '[.sessions[] | select(.steerable) | .target] | join(",")' <<<"$OUT")" api

it "carries how long it has been quiet, as a number"
assert_eq "$(state_of "$OUT" api quiet)" 60

it "carries null rather than a guess when a fact is missing"
assert_eq "$(state_of "$OUT" api/authfix age)" null

it "names the host each session is on"
assert_eq "$(state_of "$OUT" web host)" web1

it "keeps the agent's own facts alongside"
assert_eq "$(state_of "$OUT" api@review tmux.attached)" true

it "asks the agent for the tail a driver wants"
assert_contains "$(cat "$TMP/agent.log")" "--tail 6"

describe "cx peek <target> — narrowed on the server"

OUT=$(peek_json web1:api)

it "asks the agent about that unit only"
assert_contains "$(cat "$TMP/agent.log")" "--unit api"

it "answers with the unit and its labelled sessions"
assert_eq "$(jq -r '[.sessions[].target] | join(",")' <<<"$OUT")" "api,api@review"

it "does not include a worktree of the same project"
assert_not_contains "$(jq -r '[.sessions[].target] | join(",")' <<<"$OUT")" "api/authfix"

describe "cx peek <target> — against an agent that predates --unit"

OLD_AGENT=1
OUT=$(peek_json web1:api)

it "retries with the plain --all the old agent understands"
assert_eq "$(grep -c -- '--all --tail' "$TMP/agent.log")" 1

it "still answers with exactly that unit"
assert_eq "$(jq -r '[.sessions[].target] | join(",")' <<<"$OUT")" "api,api@review"
OLD_AGENT=0

describe "cx peek — the table"

rm -f "$TMP/agent.log"
cmd_peek >/dev/null 2>&1

it "asks for no tail, because the table shows no messages"
# A tail is what makes the agent read the conversations of dead sessions.
assert_contains "$(cat "$TMP/agent.log")" "--tail 0"

TABLE=$(cmd_peek 2>&1)

it "lists the sessions that are doing something"
assert_contains "$TABLE" "api@review"

it "counts finished sessions instead of listing them"
assert_not_contains "$TABLE" "api/authfix"

it "says how many it left out, and how to see them"
assert_contains "$TABLE" "1 finished"

it "lists them with --all"
assert_contains "$(cmd_peek --all 2>&1)" "api/authfix"

it "shows everything about a target it was asked about, finished or not"
assert_contains "$(cmd_peek web1:api/authfix 2>&1)" "dead"

it "leaves --json complete, because a driver revives finished sessions"
assert_eq "$(CX_JSON=1 cmd_peek 2>/dev/null | jq '[.sessions[] | select(.state == "dead")] | length')" 1

describe "cx peek --goal — one goal's members"

printf 'Host web2\n' >"$CX_SSHD_DIR/web2.conf"
export CX_GOAL_HOST=web1
rm -f "$TMP/agent.log" "$TMP/agent-hosts.log"
OUT=$(CX_JSON=1 cmd_peek --goal ship 2>/dev/null)

it "asks the goal's own server for its bare members, by exact name"
assert_contains "$(cat "$TMP/agent-hosts.log")" "web1 observe --all --slug api@review --slug api/authfix"

it "asks another server for the members qualified with it"
assert_contains "$(cat "$TMP/agent-hosts.log")" "web2 observe --all --slug dash"

it "answers with exactly the members, and no other session"
assert_eq "$(jq -r '[.sessions[] | "\(.host):\(.target)"] | sort | join(",")' <<<"$OUT")" \
  "web1:api/authfix,web1:api@review"

it "keeps a finished member, because that is what a driver revives"
assert_contains "$(cmd_peek --goal ship 2>&1)" "api/authfix"

it "falls back for an agent that predates --slug, still exactly the members"
OLD_AGENT=1
assert_eq "$(CX_JSON=1 cmd_peek --goal ship 2>/dev/null | jq -r '[.sessions[].target] | sort | join(",")')" \
  "api/authfix,api@review"
OLD_AGENT=0

it "says so for a goal that does not exist"
run_rc cmd_peek --goal nosuch
assert_eq "$_T_RC" 2

it "refuses a goal and a target together"
run_rc cmd_peek --goal ship web1:api
assert_eq "$_T_RC" 3

summary
