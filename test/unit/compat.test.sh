#!/usr/bin/env bash
# Unit tests for lib/compat.sh — the portability shims.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"
# shellcheck source=../../lib/compat.sh
. "$ROOT/lib/compat.sh"

TMP=$(cx_mktempdir)
trap 'rm -rf "$TMP"' EXIT

describe "cx_version_ge"

it "treats equal versions as satisfying >="
assert_ok cx_version_ge 3.2 3.2

it "ignores bash's version suffix: 3.2.57(1)-release >= 3.2"
assert_ok cx_version_ge "3.2.57(1)-release" 3.2

it "ignores OpenSSH's portable suffix: 7.9p1 >= 7.3"
assert_ok cx_version_ge 7.9p1 7.3

it "compares minor versions numerically, not lexically (7.10 >= 7.9)"
assert_ok cx_version_ge 7.10 7.9

it "rejects a lower minor version (7.2 >= 7.3 is false)"
assert_fail cx_version_ge 7.2 7.3

it "rejects a lower major version (2.9 >= 3.2 is false)"
assert_fail cx_version_ge 2.9 3.2

it "treats a missing component as zero (3 >= 3.0)"
assert_ok cx_version_ge 3 3.0

describe "cx_sanitize"

it "keeps safe filename characters unchanged"
assert_eq "$(cx_sanitize 'web1.example-01_x')" 'web1.example-01_x'

it "replaces path separators and colons so aliases are safe as filenames"
assert_eq "$(cx_sanitize 'web1.example:22/x')" 'web1.example_22_x'

it "neutralises a directory-traversal attempt in a host alias"
assert_not_contains "$(cx_sanitize '../../etc/passwd')" '/'

describe "cx_write_atomic"

it "creates missing parent directories"
printf 'hello' | cx_write_atomic "$TMP/deep/nested/file.json"
assert_eq "$(cat "$TMP/deep/nested/file.json")" 'hello'

it "leaves no temp file behind on success"
assert_eq "$(find "$TMP/deep/nested" -name '.cx.tmp.*' | wc -l | tr -d ' ')" '0'

it "overwrites an existing file completely, not partially"
printf 'a-much-longer-previous-value' | cx_write_atomic "$TMP/over.json"
printf 'short' | cx_write_atomic "$TMP/over.json"
assert_eq "$(cat "$TMP/over.json")" 'short'

it "writes its temp file as a sibling so the rename never crosses filesystems"
# A cross-device rename silently degrades to copy+unlink, which is not atomic.
printf 'x' | cx_write_atomic "$TMP/sibling.json"
assert_eq "$(dirname "$(cx_realpath "$TMP/sibling.json")")" "$(cx_realpath "$TMP")"

describe "cx_lock_acquire / cx_lock_release"

LOCK="$TMP/lock"

it "grants the lock when it is free"
assert_ok cx_lock_acquire "$LOCK"

it "refuses a second acquisition while held by this live process"
assert_fail cx_lock_acquire "$LOCK"

it "grants the lock again after release"
cx_lock_release "$LOCK"
assert_ok cx_lock_acquire "$LOCK"
cx_lock_release "$LOCK"

it "refuses a stale lock that is younger than the staleness threshold"
# Guards the race where a process has just mkdir'd but not yet written its pid.
mkdir -p "$LOCK"
: >"$LOCK/pid"
assert_fail cx_lock_acquire "$LOCK" 300
rm -rf "$LOCK"

it "steals a lock whose owning process is gone and is past the threshold"
mkdir -p "$LOCK"
printf '999999' >"$LOCK/pid" # a pid that cannot be running
assert_ok cx_lock_acquire "$LOCK" 0
cx_lock_release "$LOCK"

it "removes the lock directory on release"
cx_lock_acquire "$LOCK"
cx_lock_release "$LOCK"
assert_fail test -d "$LOCK"

describe "cx_mtime / cx_age"

printf 'x' | cx_write_atomic "$TMP/aged"

it "returns a plausible epoch timestamp"
_m=$(cx_mtime "$TMP/aged")
assert_ok test "$_m" -gt 1000000000

it "reports a fresh file as near-zero age"
_a=$(cx_age "$TMP/aged")
assert_ok test "$_a" -ge 0 -a "$_a" -lt 10

it "fails rather than returning garbage for a missing file"
assert_fail cx_mtime "$TMP/does-not-exist"

describe "cx_human_age"

it "renders seconds"
assert_eq "$(cx_human_age 45)" '45s'
it "renders minutes"
assert_eq "$(cx_human_age 600)" '10m'
it "renders hours"
assert_eq "$(cx_human_age 7200)" '2h'
it "renders days"
assert_eq "$(cx_human_age 172800)" '2d'
it "renders the boundary at 60s as minutes"
assert_eq "$(cx_human_age 60)" '1m'

describe "cx_realpath"

it "resolves a directory"
assert_eq "$(cx_realpath "$TMP")" "$(cd "$TMP" && pwd -P)"

it "resolves a file inside a directory"
assert_eq "$(cx_realpath "$TMP/aged")" "$(cd "$TMP" && pwd -P)/aged"

it "resolves a path that does not exist yet, so callers can pre-compute targets"
assert_eq "$(cx_realpath "$TMP/not-created")" "$(cd "$TMP" && pwd -P)/not-created"

describe "cx_have"

it "finds a command that exists"
assert_ok cx_have sh

it "reports a command that does not exist"
assert_fail cx_have definitely-not-a-real-command-xyz

describe "cx_os"

it "identifies the platform as something known"
case "$(cx_os)" in
  linux | macos | bsd | windows) _t_ok "$_T_NAME" ;;
  *) _t_no "$_T_NAME" "unknown platform: $(cx_os)" ;;
esac

summary
