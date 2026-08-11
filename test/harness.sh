#!/usr/bin/env bash
# test/harness.sh — a ~40 line assertion harness.
#
# Why not bats-core? This project's whole risk surface is "does it run on an
# unknown machine with an old bash". A test framework is one more thing to
# install before you can check that, and bats has its own version constraints.
# This harness is plain POSIX-ish bash, so `docker run bash:3.2 test/run.sh`
# works with nothing installed — which is exactly the environment we care about.

_T_PASS=0
_T_FAIL=0
_T_NAME=""

# describe GROUP — print a section header.
describe() {
  printf '\n\033[1m%s\033[0m\n' "$1"
}

# it NAME — name the assertion that follows.
it() {
  _T_NAME="$1"
}

_t_ok() {
  _T_PASS=$((_T_PASS + 1))
  printf '  \033[32m✓\033[0m %s\n' "$1"
}

_t_no() {
  _T_FAIL=$((_T_FAIL + 1))
  printf '  \033[31m✗\033[0m %s\n' "$1"
  shift
  for line in "$@"; do printf '      %s\n' "$line"; done
}

# assert_eq ACTUAL EXPECTED [NAME]
assert_eq() {
  local got="$1" want="$2" name="${3:-$_T_NAME}"
  if [ "$got" = "$want" ]; then
    _t_ok "$name"
  else
    _t_no "$name" "expected: $want" "actual:   $got"
  fi
}

# assert_ne ACTUAL NOTEXPECTED [NAME]
assert_ne() {
  local got="$1" bad="$2" name="${3:-$_T_NAME}"
  if [ "$got" != "$bad" ]; then
    _t_ok "$name"
  else
    _t_no "$name" "should not equal: $bad"
  fi
}

# assert_ok COMMAND... — command must exit 0.
assert_ok() {
  local name="$_T_NAME"
  if "$@" >/dev/null 2>&1; then
    _t_ok "$name"
  else
    _t_no "$name" "command failed (exit $?): $*"
  fi
}

# assert_fail COMMAND... — command must exit non-zero.
assert_fail() {
  local name="$_T_NAME"
  if "$@" >/dev/null 2>&1; then
    _t_no "$name" "command unexpectedly succeeded: $*"
  else
    _t_ok "$name"
  fi
}

# assert_exit CODE COMMAND... — command must exit with exactly CODE.
assert_exit() {
  local want="$1" name="$_T_NAME" got
  shift
  "$@" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    _t_ok "$name"
  else
    _t_no "$name" "expected exit $want, got $got: $*"
  fi
}

# assert_contains HAYSTACK NEEDLE [NAME]
assert_contains() {
  local hay="$1" needle="$2" name="${3:-$_T_NAME}"
  case "$hay" in
    *"$needle"*) _t_ok "$name" ;;
    *) _t_no "$name" "expected to contain: $needle" "actual: $hay" ;;
  esac
}

# assert_not_contains HAYSTACK NEEDLE [NAME]
assert_not_contains() {
  local hay="$1" needle="$2" name="${3:-$_T_NAME}"
  case "$hay" in
    *"$needle"*) _t_no "$name" "should not contain: $needle" "actual: $hay" ;;
    *) _t_ok "$name" ;;
  esac
}

# run_rc COMMAND... — run COMMAND, discard its output, and stash the exit code
# in $_T_RC for a later assert_eq.
#
# Exists because `cmd; it "..."; assert_eq "$?" 4` silently checks `it`'s exit
# status, not the command's — a trap that produces a confidently wrong test.
run_rc() {
  "$@" >/dev/null 2>&1
  _T_RC=$?
}

# skip REASON — record a skipped assertion without failing the run.
skip() {
  printf '  \033[33m-\033[0m %s \033[2m(skipped: %s)\033[0m\n' "$_T_NAME" "$1"
}

# summary — print totals, exit non-zero if anything failed.
summary() {
  printf '\n'
  if [ "$_T_FAIL" -eq 0 ]; then
    printf '\033[32m%d passed\033[0m\n' "$_T_PASS"
    return 0
  fi
  printf '\033[31m%d failed\033[0m, %d passed\n' "$_T_FAIL" "$_T_PASS"
  return 1
}
