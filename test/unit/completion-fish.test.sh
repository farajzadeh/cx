#!/usr/bin/env bash
# Unit tests for completions/cx.fish, through fish's own `complete -C`.
# Skipped without fish; completion-zsh.test.sh shows a container to run it in
# (add fish to its apk line).

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

if ! command -v fish >/dev/null 2>&1; then
  describe "fish completion"
  it "requires fish"
  skip "fish not installed"
  summary
  exit $?
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-fcomp.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/config" XDG_DATA_HOME="$TMP/data"
export CX_CACHE_DIR="$TMP/cache" CX_SSHD_DIR="$TMP/ssh.d"
mkdir -p "$HOME" "$CX_CACHE_DIR" "$CX_SSHD_DIR"
: >"$CX_SSHD_DIR/web1.conf"
printf '%s\n' web1:api web1:api/authfix web1:blog >"$CX_CACHE_DIR/targets"
printf 'web1:api@review\tworking\nweb1:blog\tdead\n' >"$CX_CACHE_DIR/state"
printf 'web1\tauth\tactive\n' >"$CX_CACHE_DIR/goals"

# fc LINE — fish's candidates for LINE, "cand desc" sorted, joined with '|'.
fc() {
  fish -c "source '$ROOT/completions/cx.fish'; complete -C '$1'" 2>&1 |
    tr '\t' ' ' | sort | tr '\n' '|'
}

has() {
  case "|$1" in
    *"|$2"*) _t_ok "$_T_NAME" ;;
    *) _t_no "$_T_NAME" "missing: [$2]" "in:      [$1]" ;;
  esac
}
lacks() {
  case "|$1" in
    *"|$2"*) _t_no "$_T_NAME" "should not offer: [$2]" "in: [$1]" ;;
    *) _t_ok "$_T_NAME" ;;
  esac
}

describe "fish completion"

it "parses"
assert_ok fish -n "$ROOT/completions/cx.fish"
it "commands, after a global flag"
has "$(fc "cx --json ")" "jump go to the tab"
it "targets, with the session's state"
has "$(fc "cx open web1:")" "web1:api@review working"
it "stop offers no dead session"
lacks "$(fc "cx stop ")" "web1:blog"
it "new offers host:"
has "$(fc "cx new ")" "web1:"
it "wt add offers project/"
has "$(fc "cx wt add ")" "web1:api/"
it "subverbs"
has "$(fc "cx goal ")" "on-stop"
it "goal names"
has "$(fc "cx goal show ")" "auth active on web1"
it "per-command flags"
has "$(fc "cx open web1:api --d")" "--dangerously-skip-permissions"
it "new and wt add take what opening the result takes"
has "$(fc "cx new web1:x --l")" "--label"
has "$(fc "cx wt add web1:api/x --eff")" "--effort"
it "find takes --print"
has "$(fc "cx find --p")" "--print"
it "ls takes its filters"
has "$(fc "cx ls --so")" "--sort"
has "$(fc "cx host ls --re")" "--reachable"
it "flag values"
has "$(fc "cx bar --icons ")" "nerd"

summary
