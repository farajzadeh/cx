#!/usr/bin/env bash
# Integration tests for the cache layer.
#
# The cache's failure modes are all "silently wrong" rather than "loudly
# broken", so these assert on behaviour a user would notice: a mutation that
# does not show up, a dead server that costs a timeout every time, a
# stampede of refreshes, a corrupt entry that wedges the command.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"
# shellcheck source=lib/nodes.sh
. "$ROOT/test/integration/lib/nodes.sh"
# cx_mtime / cx_age are used to inspect cache freshness directly.
# shellcheck source=../../lib/compat.sh
. "$ROOT/lib/compat.sh"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  describe "cache integration"
  it "requires Docker"
  skip "docker unavailable"
  summary
  exit $?
fi

nodes_build || {
  describe "cache integration"
  it "builds the node image"
  _t_no "$_T_NAME" "docker build failed"
  summary
  exit 1
}

HOME_DIR=$(nodes_env)
trap 'nodes_cleanup "$HOME_DIR"' EXIT

P1=$(nodes_start web1 "$HOME_DIR") || {
  describe "cache integration"
  it "starts a node"
  _t_no "$_T_NAME" "failed"
  summary
  exit 1
}
nodes_add_host "$HOME_DIR" cx-test-web1 "$P1"
cx_run "$HOME_DIR" provision cx-test-web1 >/dev/null 2>&1
cx_run "$HOME_DIR" new cx-test-web1:api >/dev/null 2>&1

CACHE="$HOME_DIR/.cache/cx"

_ms() { date +%s%N | cut -c1-13; }
_time_ms() {
  local s e
  s=$(_ms)
  "$@" >/dev/null 2>&1
  e=$(_ms)
  echo $((e - s))
}

# ---------------------------------------------------------------------------

describe "cache population"

cx_run "$HOME_DIR" cache clear >/dev/null 2>&1
cx_run "$HOME_DIR" ls >/dev/null 2>&1

it "writes an entry per host after a fetch"
assert_ok test -s "$CACHE/list/cx-test-web1.json"

it "writes a completion targets file that needs no network"
assert_ok test -s "$CACHE/targets"

it "targets are host:project pairs"
assert_contains "$(cat "$CACHE/targets")" 'cx-test-web1:api'

# ---------------------------------------------------------------------------

describe "warm reads are faster than cold"

cx_run "$HOME_DIR" cache clear >/dev/null 2>&1
_cold=$(_time_ms cx_run "$HOME_DIR" ls)
_warm=$(_time_ms cx_run "$HOME_DIR" ls)

it "a warm read beats a cold one"
assert_ok test "$_warm" -lt "$_cold"

it "a warm read does no SSH at all (well under a round trip)"
assert_ok test "$_warm" -lt 250

# ---------------------------------------------------------------------------

describe "mutations invalidate synchronously"

# The property that makes the cache trustworthy: no -r should ever be needed
# after your own change.
cx_run "$HOME_DIR" ls >/dev/null 2>&1 # warm it
cx_run "$HOME_DIR" new cx-test-web1:freshly-made >/dev/null 2>&1
_out=$(cx_run "$HOME_DIR" ls)

it "a newly created project appears without --refresh"
assert_contains "$_out" 'freshly-made'

cx_run "$HOME_DIR" ls >/dev/null 2>&1
cx_run "$HOME_DIR" rm cx-test-web1:freshly-made --purge >/dev/null 2>&1
_out=$(cx_run "$HOME_DIR" ls)

it "a removed project disappears without --refresh"
assert_not_contains "$_out" 'freshly-made'

# ---------------------------------------------------------------------------

describe "--refresh, --no-cache and --stale"

cx_run "$HOME_DIR" ls >/dev/null 2>&1
_before=$(cx_age "$CACHE/list/cx-test-web1.json")
sleep 1
cx_run "$HOME_DIR" -r ls >/dev/null 2>&1
_after=$(cx_age "$CACHE/list/cx-test-web1.json")

it "--refresh rewrites the entry"
assert_ok test "$_after" -le "$_before"

cx_run "$HOME_DIR" ls >/dev/null 2>&1
_mtime_before=$(cx_mtime "$CACHE/list/cx-test-web1.json")
sleep 1
cx_run "$HOME_DIR" --no-cache ls >/dev/null 2>&1
_mtime_after=$(cx_mtime "$CACHE/list/cx-test-web1.json")

it "--no-cache reads through without updating the cache"
assert_eq "$_mtime_after" "$_mtime_before"

# ---------------------------------------------------------------------------

describe "an unreachable host is remembered, not retried"

cat >"$HOME_DIR/.config/cx/ssh.d/cx-test-dead.conf" <<EOF
#cx:root=projects

Host cx-test-dead
    HostName 127.0.0.1
    User cxuser
    Port 1
    IdentityFile $HOME_DIR/.ssh/id_ed25519
EOF

cx_run "$HOME_DIR" cache clear >/dev/null 2>&1
_first=$(_time_ms cx_run "$HOME_DIR" ls)
_second=$(_time_ms cx_run "$HOME_DIR" ls)

it "records the host as down"
assert_ok test -f "$CACHE/down/cx-test-dead"

it "the second call is faster — it does not reconnect"
assert_ok test "$_second" -lt "$_first"

_out=$(cx_run "$HOME_DIR" ls)
it "still lists the reachable server's projects"
assert_contains "$_out" 'api'

it "says the view is partial rather than looking authoritative"
assert_contains "$_out" 'unreachable'

_out=$(cx_run "$HOME_DIR" cache status)
it "cache status shows the unreachable host"
assert_contains "$_out" 'unreachable'

it "cache status distinguishes it from a cached host"
assert_contains "$_out" 'fresh'

# ---------------------------------------------------------------------------

describe "offline mode"

_out=$(env CX_STALE_OK=1 bash -c '
  HOME="$1"; export HOME
  CX_HOME="$2"; export CX_HOME
  CX_CONFIG_DIR="$1/.config/cx" CX_CONFIG_FILE="$1/.config/cx/config"
  CX_SSHD_DIR="$1/.config/cx/ssh.d" CX_CACHE_DIR="$1/.cache/cx"
  CX_SSH_CONFIG="$1/.ssh/config" CX_STALE_OK=1 NO_COLOR=1
  export CX_CONFIG_DIR CX_CONFIG_FILE CX_SSHD_DIR CX_CACHE_DIR CX_SSH_CONFIG CX_STALE_OK NO_COLOR
  bash "$2/bin/cx" ls 2>&1' _ "$HOME_DIR" "$ROOT")

it "CX_STALE_OK renders from cache regardless of age"
assert_contains "$_out" 'api'

rm -f "$HOME_DIR/.config/cx/ssh.d/cx-test-dead.conf"

# ---------------------------------------------------------------------------

describe "concurrent stale reads do not stampede"

printf 'CX_CACHE_TTL=1\n' >>"$HOME_DIR/.config/cx/config"
cx_run "$HOME_DIR" ls >/dev/null 2>&1
sleep 2

for _i in 1 2 3 4 5; do
  cx_run "$HOME_DIR" ls >/dev/null 2>&1 &
done
wait
sleep 2

it "leaves no lock directories behind"
assert_eq "$(ls "$CACHE/lock" 2>/dev/null | wc -l | tr -d ' ')" '0'

it "the cache is still valid JSON after concurrent refreshes"
run_rc jq -e . "$CACHE/list/cx-test-web1.json"
assert_eq "$_T_RC" 0

# ---------------------------------------------------------------------------

describe "a corrupt entry heals rather than wedging"

printf 'this is not json' >"$CACHE/list/cx-test-web1.json"
_out=$(cx_run "$HOME_DIR" ls)

it "does not crash on a corrupt cache file"
assert_not_contains "$_out" 'parse error'

it "reports the host rather than emitting garbage"
assert_contains "$_out" 'cx-test-web1'

# ---------------------------------------------------------------------------

describe "the cache is disposable"

rm -rf "$CACHE"
_out=$(cx_run "$HOME_DIR" ls)

it "deleting the whole cache directory changes nothing but speed"
assert_contains "$_out" 'api'

it "and it is rebuilt"
assert_ok test -s "$CACHE/list/cx-test-web1.json"

# ---------------------------------------------------------------------------

describe "cx cache clear"

_out=$(cx_run "$HOME_DIR" cache clear)
it "reports success"
assert_contains "$_out" 'cleared'

it "removes the entries"
assert_fail test -s "$CACHE/list/cx-test-web1.json"

summary
