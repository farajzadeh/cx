#!/usr/bin/env bash
# Unit tests for the status bar: cx_activity_rows (lib/activity.sh), which
# turns one host's observe payload into classified rows, and cmd_bar, which
# renders them into a single tmux line.
#
# Both are exercised without a server. The bar's whole contract is what it
# prints — a count, a priority order, a width limit, and silence when nothing
# needs you — so a stubbed cx_agent is enough to pin all of it. The one thing
# a unit test cannot check is the SSH fan-out itself; test/integration covers
# that shape for cx peek already.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

export CX_HOME="$ROOT"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-bar.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

export CX_CACHE_DIR="$TMP/cache"
export CX_SSHD_DIR="$TMP/ssh.d"
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
# shellcheck source=../../lib/cmd/bar.sh
. "$ROOT/lib/cmd/bar.sh"

NOW=$(cx_now)

# Everything here reads an observe payload, and reading JSON means jq. cx
# requires it in production, but the bash:3.2 image used by `test/run.sh
# --bash32` does not carry it — and that run is asking about bash, not about
# jq. Skip rather than fail, the same way test/unit/activity.test.sh does.
if ! cx_have jq; then
  describe "cx bar"
  it "needs jq"
  skip "jq unavailable"
  summary
  exit $?
fi

# The stub must be installed AFTER bar.sh, which sources lib/remote.sh and
# would otherwise define the real cx_agent over the top of it.
#
# It answers from $TMP/<host>.json, and fails with 255 — ssh's own "could not
# connect" — when there is no such file, which is how an unreachable server is
# simulated.
cx_agent() {
  local h="$1"
  [ -f "$TMP/$h.json" ] || return 255
  cat "$TMP/$h.json"
}

host() {
  printf 'Host %s\n' "$1" >"$CX_SSHD_DIR/$1.conf"
}

# session TARGET STATE — one entry for an observe payload.
#
# The facts are chosen to land on STATE through the real classifier rather
# than asserted directly, so these fixtures cannot drift away from what
# cx_activity_state actually does.
session() {
  local target="$1" state="$2" attached="${3:-false}"
  case "$state" in
    idle) printf '{"target":"%s","tmux":{"alive":true,"attached":%s,"shell":false,"created":%s},"transcript":{"uuid":"u","present":true,"mtime":%s},"last":{"role":"assistant","stop_reason":"end_turn"}}' "$target" "$attached" "$((NOW - 900))" "$((NOW - 60))" ;;
    blocked) printf '{"target":"%s","tmux":{"alive":true,"attached":%s,"shell":false,"created":%s},"transcript":{"uuid":"u","present":true,"mtime":%s},"last":{"role":"assistant","stop_reason":"tool_use"}}' "$target" "$attached" "$((NOW - 900))" "$((NOW - 3000))" ;;
    working) printf '{"target":"%s","tmux":{"alive":true,"attached":%s,"shell":false,"created":%s},"transcript":{"uuid":"u","present":true,"mtime":%s},"last":{"role":"assistant","stop_reason":"tool_use"}}' "$target" "$attached" "$((NOW - 900))" "$((NOW - 5))" ;;
    fresh) printf '{"target":"%s","tmux":{"alive":true,"attached":%s,"shell":false,"created":%s},"transcript":{"uuid":"u","present":false,"mtime":null},"last":null}' "$target" "$attached" "$((NOW - 30))" ;;
    dead) printf '{"target":"%s","tmux":{"alive":false,"attached":false,"shell":false,"created":null},"transcript":{"uuid":"u","present":true,"mtime":%s},"last":{"role":"user","stop_reason":null}}' "$target" "$((NOW - 99))" ;;
  esac
}

# payload HOST ENTRY... — write one host's observe answer.
payload() {
  local h="$1" sep=""
  shift
  {
    printf '{"sessions":['
    for e in "$@"; do
      printf '%s%s' "$sep" "$e"
      sep=,
    done
    printf ']}'
  } >"$TMP/$h.json"
}

reset_hosts() {
  rm -f "$CX_SSHD_DIR"/*.conf "$TMP"/*.json 2>/dev/null || true
  cx_cache_invalidate
}

# ---------------------------------------------------------------------------

describe "cx_activity_rows — one host's payload, classified"

reset_hosts
payload web1 \
  "$(session api idle)" \
  "$(session api@review blocked)" \
  "$(session api/wt working)" \
  "$(session gone dead)"
ROWS=$(cx_activity_rows web1 "$TMP/web1.json" "$NOW")

it "emits one row per session"
assert_eq "$(printf '%s\n' "$ROWS" | grep -c .)" 4

it "carries the host, the target and the state"
assert_eq "$(printf '%s\n' "$ROWS" | head -1)" "$(printf 'web1\tapi\tidle\tfalse\t60\t900')"

it "writes - for a missing number rather than an empty column"
# The trap this guards: with IFS=TAB, `read` folds runs of tabs together and
# drops empty fields, so one blank column shifts every later one left. A dead
# session has no creation time, and its row is where that would first bite.
assert_eq "$(printf '%s\n' "$ROWS" | grep '^web1	gone' | cut -f6)" "-"

it "still reads back into the right variables when fields are missing"
# shellcheck disable=SC2034
printf '%s\n' "$ROWS" | grep '^web1	gone' |
  while IFS='	' read -r h t s a q g; do printf '%s|%s|%s' "$s" "$q" "$g"; done >"$TMP/read"
assert_eq "$(cat "$TMP/read")" "dead|99|-"

it "says nothing about a payload with no sessions"
printf '{"sessions":[]}' >"$TMP/empty.json"
assert_eq "$(cx_activity_rows web1 "$TMP/empty.json" "$NOW")" ""

it "survives a payload that is not the shape it expected"
printf 'not json at all' >"$TMP/junk.json"
assert_eq "$(cx_activity_rows web1 "$TMP/junk.json" "$NOW")" ""

# ---------------------------------------------------------------------------

describe "cx bar — what lands in the status line"

reset_hosts
host web1
payload web1 \
  "$(session api idle)" \
  "$(session api@review blocked)" \
  "$(session api/wt working)"

it "counts the sessions waiting — not the sessions — and names them"
assert_eq "$(cmd_bar --plain)" "cx 2: api@review api"

it "puts blocked before idle, because --states is a priority order"
assert_eq "$(cmd_bar --plain --states idle,blocked)" "cx 2: api api@review"

it "counts only the states asked for"
assert_eq "$(cmd_bar --plain --states working)" "cx 1: api/wt"

it "does not qualify names with the host when there is only one server"
assert_not_contains "$(cmd_bar --plain)" "web1:"

it "styles blocked and idle differently for tmux"
assert_contains "$(cmd_bar)" "#[fg=yellow]api@review#[default]"

it "leads with the colour of the most urgent state"
assert_contains "$(cmd_bar)" "#[fg=yellow]cx 2:"

it "names at most --max of them, and counts the rest"
assert_eq "$(cmd_bar --plain --max 1)" "cx 2: api@review +1"

it "reports the count alone at --max 0"
assert_eq "$(cmd_bar --plain --max 0)" "cx 2"

it "drops the label when asked"
assert_eq "$(cmd_bar --plain --label '')" "2: api@review api"

it "prints nothing at all when nothing is waiting"
# An empty line is the whole point: the status bar collapses rather than
# holding space for a message about there being no message.
payload web1 "$(session api working)"
assert_eq "$(cmd_bar --plain)" ""

it "exits 0 with nothing to say"
run_rc cmd_bar --plain
assert_eq "$_T_RC" 0

it "leaves out a session you already have attached"
payload web1 "$(session api idle true)" "$(session api@review idle)"
assert_eq "$(cmd_bar --plain)" "cx 1: api@review"

it "includes it with --attached"
assert_eq "$(cmd_bar --plain --attached)" "cx 2: api api@review"

it "says nothing when no server is configured"
reset_hosts
assert_eq "$(cmd_bar --plain)" ""

# ---------------------------------------------------------------------------

describe "cx bar — more than one server"

reset_hosts
host web1
host web2
payload web1 "$(session api idle)"
payload web2 "$(session dash blocked)"

it "qualifies names with the host once there are two"
assert_eq "$(cmd_bar --plain)" "cx 2: web2:dash web1:api"

it "names a server it could not reach instead of quietly dropping it"
# An empty bar has to mean "nothing needs you". A server that did not answer
# is not the same fact, and hiding it turns the bar into a lie the moment a
# VPN drops.
rm -f "$TMP/web2.json"
assert_eq "$(cmd_bar --plain)" "cx 1: web1:api !web2"

it "reports the unreachable server even when nothing at all is waiting"
payload web1 "$(session api working)"
assert_eq "$(cmd_bar --plain)" "!web2"

it "remembers it is down, so the next redraw does not wait on it again"
assert_ok cx_cache_is_down web2

it "does not mark a host down when the host answered and the agent did not"
# 255 is ssh failing to connect; anything else came back from the far side, so
# the server is up. Marking it down there would make cx ls claim it is
# unreachable for the next minute, which it is not.
reset_hosts
host web3
cx_agent() { return 127; }
run_rc cmd_bar --plain
assert_fail cx_cache_is_down web3

# ---------------------------------------------------------------------------

describe "cx bar — arguments"

it "rejects an unknown state"
assert_exit 3 cmd_bar --states nonsense

it "rejects a non-numeric --max"
assert_exit 3 cmd_bar --max lots

it "rejects an unknown option"
assert_exit 3 cmd_bar --follow

it "rejects a target, because the bar is every session or none"
assert_exit 3 cmd_bar web1:api

it "prints tmux configuration for --setup"
assert_contains "$(cmd_bar --setup)" 'set -g status-right "#('

it "points --setup at cx by absolute path, since tmux has its own PATH"
assert_contains "$(cmd_bar --setup)" "$ROOT/bin/cx bar"

summary
