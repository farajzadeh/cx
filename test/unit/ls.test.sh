#!/usr/bin/env bash
# Unit tests for `cx ls` output.
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

summary
