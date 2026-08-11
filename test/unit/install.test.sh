#!/usr/bin/env bash
# Unit tests for install.sh.
#
# install.sh cannot source lib/compat.sh (it runs before the repo exists), so
# it carries its own copy of version_ge. These tests exist specifically to
# catch the two copies drifting apart.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

CX_INSTALL_LIB_ONLY=1
export CX_INSTALL_LIB_ONLY
# shellcheck source=../../install.sh
. "$ROOT/install.sh"

describe "install.sh version_ge (must match lib/compat.sh)"

it "accepts equal versions"
assert_ok version_ge 3.2 3.2

it "accepts bash's suffixed version against the 3.2 floor"
assert_ok version_ge "3.2.57(1)-release" 3.2

it "accepts OpenSSH's portable suffix against the 7.3 floor"
assert_ok version_ge 9.6p1 7.3

it "rejects OpenSSH 7.2, which predates ssh_config Include"
assert_fail version_ge 7.2 7.3

it "compares numerically rather than lexically (7.10 >= 7.9)"
assert_ok version_ge 7.10 7.9

describe "install.sh agrees with lib/compat.sh"

# Load the real shim under a different name and compare on a matrix of cases.
# Drift between these two implementations would mean install.sh admits a
# machine that cx itself then fails on, or vice versa.
_compat_ge() (
  # shellcheck source=../../lib/compat.sh
  . "$ROOT/lib/compat.sh"
  cx_version_ge "$1" "$2"
)

for case_pair in \
  "3.2:3.2" "3.1:3.2" "5.2.21:3.2" "3.2.57(1)-release:3.2" \
  "7.3:7.3" "7.2:7.3" "9.6p1:7.3" "7.10:7.9" "10.0:9.9" "1.7.1:1.6"; do
  _a="${case_pair%%:*}"
  _b="${case_pair##*:}"
  if version_ge "$_a" "$_b"; then _r1=y; else _r1=n; fi
  if _compat_ge "$_a" "$_b"; then _r2=y; else _r2=n; fi
  it "both agree on '$_a' >= '$_b'"
  assert_eq "$_r1" "$_r2"
done

describe "install_hint"

it "renders an apt command when apt-get is the package manager"
_out=$(detect_pm() { echo apt-get; } && install_hint jq)
assert_contains "$_out" 'apt-get install'

it "renders a brew command on macOS with Homebrew present"
_out=$(detect_pm() { echo brew; } && install_hint jq)
assert_eq "$_out" 'brew install jq'

it "tells macOS users without Homebrew how to get it"
_out=$(detect_pm() { echo none-macos; } && install_hint jq)
assert_contains "$_out" 'brew.sh'

it "degrades to generic advice on an unrecognised package manager"
_out=$(detect_pm() { echo none; } && install_hint jq)
assert_contains "$_out" 'package manager'

describe "exit code constants are the documented contract"

it "0 means ready"
assert_eq "$EXIT_OK" 0
it "1 means a required dependency is missing"
assert_eq "$EXIT_MISSING_REQUIRED" 1
it "2 means only optional dependencies are missing"
assert_eq "$EXIT_MISSING_OPTIONAL" 2
it "3 means unsupported platform"
assert_eq "$EXIT_UNSUPPORTED" 3

describe "detect_os"

it "recognises this machine"
case "$(detect_os)" in
  linux | macos | bsd | windows) _t_ok "$_T_NAME" ;;
  *) _t_no "$_T_NAME" "got: $(detect_os)" ;;
esac

summary
