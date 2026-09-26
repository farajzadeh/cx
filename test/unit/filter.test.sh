#!/usr/bin/env bash
# Unit tests for lib/filter.sh — the pattern matcher and duration parser that
# `cx ls`, `cx host ls` and `cx wt ls` share.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"
# shellcheck source=../../lib/compat.sh
. "$ROOT/lib/compat.sh"
# shellcheck source=../../lib/filter.sh
. "$ROOT/lib/filter.sh"

describe "cx_duration_secs"

for c in 90:90 90s:90 30m:1800 2h:7200 7d:604800 2w:1209600 0:0 08h:28800 010m:600; do
  it "${c%%:*} is ${c#*:} seconds"
  assert_eq "$(cx_duration_secs "${c%%:*}")" "${c#*:}"
done

for bad in "" x 3x m 1.5h -2h 2hh "2 h"; do
  it "'$bad' is a usage error, 3"
  rc=0
  cx_duration_secs "$bad" >/dev/null || rc=$?
  assert_eq "$rc" 3
done

describe "cx_filter_split_list"

it "splits commas, flattens arguments, drops empties"
assert_eq "$(cx_filter_split_list ",web1,,web2" "web3" "" | tr '\n' ' ')" "web1 web2 web3 "

describe "cx_match"

if ! cx_have jq; then
  it "needs jq"
  skip "jq unavailable"
  summary
  exit $?
fi

matches() {
  if cx_filter_test "$1" "$2"; then printf yes; else printf no; fi
}

# pattern : string : expected
while IFS=: read -r p s want; do
  it "'$p' against '$s' is $want"
  assert_eq "$(matches "$p" "$s")" "$want"
done <<'EOF'
api:api:yes
api:myapi-server:yes
API:myapi:yes
api:Api-Gateway:yes
apx:api:no
api*:apiserver:yes
api*:myapi:no
*fix:authfix:yes
*fix:authfixed:no
a*f*x:authfix:yes
a*z*x:authfix:no
a**x:ax:yes
ab*ba:aba:no
ab*ba:abba:yes
*::yes
*:anything:yes
x.y:x.y:yes
x.y:xzy:no
a?:a?:yes
a?:ab:no
[ab]:[ab]:yes
[ab]:a:no
EOF

it "null never matches, even *"
assert_eq "$(jq -n "$CX_FILTER_JQ"' null | cx_match("*")')" false

it "an empty pattern matches everything, null included"
assert_eq "$(jq -n "$CX_FILTER_JQ"' [null] | cx_any("")')" true

it "cx_any is true when any field matches"
assert_eq "$(jq -n "$CX_FILTER_JQ"' [null, "main", "web1:api"] | cx_any("web1:*")')" true

it "non-ASCII survives the glob"
assert_eq "$(matches '*é*' 'café-ü')" yes

summary
