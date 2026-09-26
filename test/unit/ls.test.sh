#!/usr/bin/env bash
# Unit tests for `cx ls`: its plain output, pinned, and its filters,
# grouping and sorting.
#
# Everything is served from cached listings under CX_FORCE_STALE=1, as in
# test/unit/pick.test.sh, so no server is contacted: web3 is marked down,
# which is what a fan-out does with a host it remembers as unreachable.
#
# Timestamps are written relative to now, so the ACTIVE column is stable.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"
# shellcheck source=../../lib/compat.sh
. "$ROOT/lib/compat.sh"

if ! cx_have jq; then
  describe "cx ls filters"
  it "needs jq"
  skip "jq unavailable"
  summary
  exit $?
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-ls.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

export CX_HOME="$ROOT"
export CX_CACHE_DIR="$TMP/cache" CX_SSHD_DIR="$TMP/ssh.d"
export CX_CONFIG_FILE="$TMP/no-such-config" CX_SSH_CONFIG="$TMP/ssh_config"
export CX_FORCE_STALE=1 CX_NO_COLOR=1 NO_COLOR=1
unset CX_LS_GROUP CX_LS_SORT CX_DEFAULT_HOST CX_JSON
printf 'Include %s/*.conf\n' "$CX_SSHD_DIR" >"$CX_SSH_CONFIG"

mkdir -p "$CX_SSHD_DIR" "$CX_CACHE_DIR/list" "$CX_CACHE_DIR/down"
n=0
for h in web1 web2 web3; do
  n=$((n + 1))
  printf 'Host %s\n  HostName 192.0.2.%s\n  User me\n' "$h" "$n" >"$CX_SSHD_DIR/$h.conf"
done
: >"$CX_CACHE_DIR/down/web3"

NOW=$(date +%s)
M10=$((NOW - 600))
H2=$((NOW - 7200))
H3=$((NOW - 10800))
D10=$((NOW - 864000))
M1=$((NOW - 60))

cat >"$CX_CACHE_DIR/list/web1.json" <<EOF
{"host":"web1","ok":true,"projects":[
 {"name":"api","branch":"main","repo":"git@github.com:me/api.git","sessions":3,
  "last_active":$M10,"tmux_live":true,"tmux_count":2,
  "worktrees":[
   {"name":"authfix","branch":"authfix","sessions":1,"last_active":$H2,
    "tmux_live":true,"tmux_count":1,"merged":false},
   {"name":"docs","branch":"docs-update","sessions":0,"last_active":null,
    "tmux_live":false,"tmux_count":0,"merged":true}]},
 {"name":"site","branch":"dev","repo":null,"sessions":0,"last_active":null,
  "tmux_live":false,"tmux_count":0,"worktrees":[]},
 {"name":"legacy","branch":"master","repo":"https://gitlab.com/x/legacy.git",
  "sessions":5,"last_active":$D10,"tmux_live":false,"tmux_count":0,"worktrees":[]}
]}
EOF
cat >"$CX_CACHE_DIR/list/web2.json" <<EOF
{"host":"web2","ok":true,"projects":[
 {"name":"blog","branch":"main","repo":null,"sessions":1,"last_active":$H3,
  "tmux_live":false,"tmux_count":0,
  "worktrees":[
   {"name":"redesign","branch":"redesign","sessions":2,"last_active":$M1,
    "tmux_live":true,"tmux_count":1}]},
 {"name":"Api-Gateway","branch":"main","repo":null,"sessions":0,"last_active":null,
  "tmux_live":false,"tmux_count":0}
]}
EOF

cx() { "$ROOT/bin/cx" "$@" 2>&1; }
cxo() { "$ROOT/bin/cx" "$@" 2>/dev/null; }
rc_of() {
  local rc=0
  "$ROOT/bin/cx" "$@" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}
# names — the PROJECT column of a table on stdout, space-separated. A host
# heading (a row of one cell) comes out as [host].
names() {
  awk 'NR == 1 || !NF { next }
       NF == 1 { printf "[%s] ", $1; next }
       $1 ~ /^web[0-9]$/ { printf "%s ", $2; next }
       { printf "%s ", $1 }'
}
# jnames — "host:name[wt,...]" per project, from --json.
jnames() {
  jq -r '.projects[] | "\(.host):\(.name)"
    + (if has("worktrees") then "[" + ([.worktrees[].name] | join(",")) + "]" else "" end)' |
    tr '\n' ' '
}

# norm — absolute timestamps back to their names, so JSON can be compared.
norm() { sed -e "s/$M10/M10/g; s/$H2/H2/g; s/$H3/H3/g; s/$D10/D10/g; s/$M1/M1/g"; }
GOLD="$ROOT/test/fixtures/ls"

# table — a table as the goldens were captured, i.e. by an awk that counts
# characters. busybox awk counts bytes, so cx_table pads a row holding ● or —
# differently there, before and after this change alike; on such an awk only
# runs of spaces are compared, which still pins every cell and every row.
if [ "$(printf '\342\227\217' | awk '{ print length($0) }')" = 1 ]; then
  table() { cat; }
else
  table() { tr -s ' '; }
fi

describe "plain cx ls is unchanged"

# Captured from `cx ls` before filtering existed. Any difference here is a
# change to the default output, which scripts and eyes both depend on. They
# are never regenerated from the current code — that would test nothing.
it "the default table is byte-identical"
assert_eq "$(cx ls | table)" "$(table <"$GOLD/default.txt")"
it "the default --json is byte-identical"
assert_eq "$(cx ls --json | norm)" "$(cat "$GOLD/default.json")"
it "cx ls <host> is byte-identical"
assert_eq "$(cx ls web2 | table)" "$(table <"$GOLD/host.txt")"
it "--group none and --sort none are the defaults"
assert_eq "$(cx ls --group none --sort none | table)" "$(table <"$GOLD/default.txt")"
it "--group does not change the JSON"
assert_eq "$(cx ls --json --group host | norm)" "$(cat "$GOLD/default.json")"

describe "patterns"

it "plain text is a case-insensitive substring"
assert_eq "$(cxo ls API | names)" "api api/authfix api/docs Api-Gateway "

it "a project that matches keeps all its worktrees"
assert_eq "$(cxo --json ls api | jnames)" "web1:api[authfix,docs] web2:Api-Gateway "

it "a worktree match shows its project as a heading, with only that worktree"
assert_eq "$(cxo ls auth | names)" "api api/authfix "

it "branches match"
assert_eq "$(cxo ls docs-update | names)" "api api/docs "

it "repos match"
assert_eq "$(cxo ls gitlab | names)" "legacy "

it "* makes it a glob over the whole field"
assert_eq "$(cxo ls '*fix' | names)" "api api/authfix "
assert_eq "$(cxo ls 'api*' | names)" "api api/authfix api/docs Api-Gateway " "a leading anchor"
assert_eq "$(cxo ls 'a*y' | names)" "Api-Gateway " "both ends anchored"

it "the target forms are fields too"
assert_eq "$(cxo ls 'web2:*' | names)" "blog blog/redesign Api-Gateway "
assert_eq "$(cxo ls 'blog/*' | names)" "blog blog/redesign " "project/worktree"

it "-f is the same as a positional pattern"
assert_eq "$(cxo ls -f auth | names)" "api api/authfix "

it "-f can search for text that is a host's name"
assert_eq "$(cxo ls -f web2 | names)" "blog blog/redesign Api-Gateway "

it "a pattern still announces unreachable servers — they might hold a match"
assert_contains "$(cx ls auth)" "web3 unreachable"

it "says so when nothing matches"
assert_contains "$(cx ls zzz)" "Nothing matches"

it "exits 0 when nothing matches"
assert_eq "$(rc_of ls zzz)" 0

describe "host or pattern"

it "a configured host is a host"
assert_eq "$(cxo ls web2 | names)" "blog blog/redesign Api-Gateway "

it "a host narrows the fan-out: no warning about other servers"
assert_not_contains "$(cx ls web2)" "web3"

it "host then pattern"
assert_eq "$(cxo ls web1 auth | names)" "api api/authfix "

it "a word that is not a host is a pattern, and the empty result says so"
out=$(cx ls wbe1)
assert_contains "$out" "'wbe1' is not a configured host"

it "an unknown host followed by a pattern is an error, 2"
assert_eq "$(rc_of ls wbe1 auth)" 2

it "two patterns are a usage error, 3"
assert_eq "$(rc_of ls web1 auth -f blog)" 3

describe "--host"

it "limits the servers"
assert_eq "$(cxo --json ls --host web2 | jnames)" "web2:blog[redesign] web2:Api-Gateway "

it "takes a comma list, and repeats"
assert_eq "$(cxo --json ls --host web1,web2 | jq -r '[.servers[].host] | join(" ")')" "web1 web2"
assert_eq "$(cxo --json ls --host web1 --host web2 | jq -r '[.servers[].host] | join(" ")')" \
  "web1 web2" "repeated"

it "announces only the servers it was asked about"
assert_not_contains "$(cx ls --host web1,web2)" "web3"
assert_contains "$(cx ls --host web1,web3)" "web3 unreachable" "an unreachable one in scope"

it "an unknown host is not found, 2"
assert_eq "$(rc_of ls --host web1,nope)" 2

describe "state filters"

it "--live: something is running"
assert_eq "$(cxo ls --live | names)" "api api/authfix blog blog/redesign "

it "--active: touched within the window"
assert_eq "$(cxo ls --active 1h | names)" "api blog blog/redesign "

it "--idle: untouched for the window, never-touched included"
assert_eq "$(cxo ls --idle 1d | names)" "api api/docs site legacy Api-Gateway "

it "--active and --idle together are a window"
assert_eq "$(cxo ls --idle 1h --active 1d | names)" "api api/authfix blog "

it "--no-worktrees drops worktrees, and projects only a worktree matched"
assert_eq "$(cxo ls --no-worktrees auth | names)" ""
assert_eq "$(cxo ls --no-worktrees api | names)" "api Api-Gateway " "a project match survives"

it "--no-worktrees leaves no worktrees key in the JSON"
assert_eq "$(cxo --json ls --no-worktrees --host web2 | jnames)" "web2:blog web2:Api-Gateway "

it "--live with --json filters worktrees inside a project"
assert_eq "$(cxo --json ls --live | jnames)" "web1:api[authfix] web2:blog[redesign] "

it "the JSON keeps its shape"
assert_eq "$(cxo --json ls --live | jq -c 'keys')" '["projects","servers"]'

it "a bad duration is a usage error, 3"
assert_eq "$(rc_of ls --idle 3x)" 3

describe "sorting"

it "--sort name, worktrees too"
assert_eq "$(cxo ls --sort name | names)" \
  "api api/authfix api/docs Api-Gateway blog blog/redesign legacy site "

it "--sort active: most recent first, a worktree counting for its project"
assert_eq "$(cxo ls --sort active | names)" \
  "blog blog/redesign api api/authfix api/docs legacy site Api-Gateway "

it "--sort sessions: most first, worktrees included"
assert_eq "$(cxo ls --sort sessions --no-worktrees | names)" \
  "legacy api blog site Api-Gateway "

it "--sort host: host, then name"
assert_eq "$(cxo ls --sort host --no-worktrees | names)" "api legacy site Api-Gateway blog "

it "--sort applies to the JSON"
assert_eq "$(cxo --json ls --sort name --no-worktrees | jnames)" \
  "web1:api web2:Api-Gateway web2:blog web1:legacy web1:site "

it "an unknown key is a usage error, 3"
assert_eq "$(rc_of ls --sort size)" 3

describe "grouping"

it "--group host puts a heading over each server's projects"
assert_eq "$(cxo ls --group host | names)" \
  "[web1] api api/authfix api/docs site legacy [web2] blog blog/redesign Api-Gateway "

it "drops the HOST column"
assert_eq "$(cxo ls --group host | head -1 | awk '{print $1}')" "PROJECT"

it "indents under the heading"
assert_contains "$(cxo ls --group host)" "$(printf '\n  api ')"

it "servers keep fan-out order, --sort orders within each"
assert_eq "$(cxo ls --group host --sort name --no-worktrees | names)" \
  "[web1] api legacy site [web2] Api-Gateway blog "

it "servers keep the order --host gave"
assert_eq "$(cxo ls --group host --host web2,web1 --no-worktrees | names)" \
  "[web2] blog Api-Gateway [web1] api site legacy "

it "a server with nothing left gets no heading"
assert_eq "$(cxo ls --group host --live | names)" \
  "[web1] api api/authfix [web2] blog blog/redesign "
assert_eq "$(cxo ls --group host gitlab | names)" "[web1] legacy " "only the one with a match"

it "an unknown layout is a usage error, 3"
assert_eq "$(rc_of ls --group project)" 3

describe "defaults from the environment"

it "CX_LS_GROUP and CX_LS_SORT set the defaults"
assert_eq "$(CX_LS_GROUP=host CX_LS_SORT=name cxo ls --no-worktrees | names)" \
  "[web1] api legacy site [web2] Api-Gateway blog "

it "flags beat them"
assert_eq "$(CX_LS_GROUP=host CX_LS_SORT=name cx ls --group none --sort none | table)" \
  "$(table <"$GOLD/default.txt")"

it "the config file sets them too"
printf 'CX_LS_SORT=name\n' >"$TMP/config"
assert_eq "$(CX_CONFIG_FILE="$TMP/config" cxo ls --no-worktrees --host web1 | names)" \
  "api legacy site "

it "a bad value is a config error, 78"
assert_eq "$(CX_LS_SORT=size rc_of ls)" 78

describe "combinations"

it "host, pattern, state, sort and group together"
assert_eq "$(cxo ls web1 a --live --sort name --group host | names)" "[web1] api api/authfix "

it "every filter must pass"
assert_eq "$(cxo ls blog --live --active 5m | names)" "blog blog/redesign "
assert_eq "$(cxo ls blog --live --idle 5m | names)" "" "a contradiction leaves nothing"

summary
