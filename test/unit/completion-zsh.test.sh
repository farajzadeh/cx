#!/usr/bin/env bash
# Unit tests for completions/cx.zsh and the oh-my-zsh plugin.
#
# Needs zsh with the zsh/zpty module; skipped without one. To run it where
# zsh is not installed:
#
#   docker build -t cx-zsh - <<<'FROM alpine:3.22
#   RUN apk add --no-cache zsh bash'
#   docker run --rm -v "$PWD":/w -w /w cx-zsh bash test/unit/completion-zsh.test.sh
#
# Each case runs a real interactive zsh in a pseudo-terminal, presses TAB and
# records what compadd was given (test/fixtures/completion/capture.zsh), so it
# exercises _arguments, the tags and the groups exactly as a user's shell does.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

if ! command -v zsh >/dev/null 2>&1 || ! zsh -fc 'zmodload zsh/zpty' 2>/dev/null; then
  describe "zsh completion"
  it "requires zsh with zsh/zpty"
  skip "zsh not installed"
  summary
  exit $?
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-zcomp.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export TMPDIR="$TMP" HOME="$TMP/home"
export CX_CACHE_DIR="$TMP/cache" CX_SSHD_DIR="$TMP/ssh.d" CX_SSH_CONFIG="$TMP/ssh_config"
mkdir -p "$HOME" "$CX_CACHE_DIR" "$CX_SSHD_DIR"
: >"$CX_SSHD_DIR/web1.conf"
: >"$CX_SSHD_DIR/web2.conf"
printf '%s\n' web1:api web1:api/authfix web1:blog web2:dash >"$CX_CACHE_DIR/targets"
printf 'web1:api\tidle\nweb1:api@review\tworking\nweb1:api/authfix@tests\tblocked\nweb2:dash\tdead\n' \
  >"$CX_CACHE_DIR/state"
printf 'web1\tauth\tactive\n' >"$CX_CACHE_DIR/goals"

# zc LINE — "tag match suffix desc" rows, sorted, joined with '|'.
zc() {
  zsh -f "$ROOT/test/fixtures/completion/capture.zsh" "$1" 2>/dev/null |
    tr '\t' ' ' | sed 's/ *$//' | sort | tr '\n' '|'
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

describe "loading"

it "parses (zsh -n)"
assert_ok zsh -n "$ROOT/completions/cx.zsh"
it "the oh-my-zsh plugin parses"
assert_ok zsh -n "$ROOT/completions/omz/cx/cx.plugin.zsh"
it "the plugin's _cx resolves to the same file"
assert_eq "$(cd "$ROOT/completions/omz/cx" && cat _cx | cksum)" "$(cksum <"$ROOT/completions/cx.zsh")"

for mode in fpath source; do
  export CX_ZTEST_MODE=$mode

  describe "completing ($mode)"

  out=$(zc "cx ")
  it "commands, with descriptions"
  has "$out" "commands open - attach a Claude session"
  it "includes the newer commands"
  has "$out" "commands jump -"

  it "global flags before the command do not move it"
  has "$(zc "cx --json l")" "commands ls -"

  out=$(zc "cx open ")
  it "servers in their own group, completed up to the colon"
  has "$out" "hosts web2 :"
  it "projects in their own group, described by their state"
  has "$out" "projects web1:api  idle"
  it "a project with nothing under it is final"
  has "$out" "projects web1:blog - project"

  out=$(zc "cx open web1:api")
  it "worktrees in their own group"
  has "$out" "worktrees web1:api/authfix  worktree"
  it "sessions in their own group, with what they are doing"
  has "$out" "sessions web1:api@review - working"

  it "stop offers no dead session"
  lacks "$(zc "cx stop web2:")" "projects web2:dash"

  it "per-command flags, with descriptions"
  has "$(zc "cx open web1:api --d")" "options --dangerously-skip-permissions - bypass ALL permission checks"
  it "and the global flags after the command"
  has "$(zc "cx ls --n")" "options --no-cache -"

  it "subverbs"
  has "$(zc "cx wt ")" "subcommands add - a worktree"
  it "goal names from the local cache"
  has "$(zc "cx goal show ")" "goals auth - active on web1"
  it "flag values"
  has "$(zc "cx bar --icons ")" "option--icons-1 nerd -"
  it "a comma list of states"
  has "$(zc "cx jump --states blocked,")" "values blocked,idle"
  it "new completes host: only"
  assert_eq "$(zc "cx new w")" "hosts web1 : server|hosts web2 : server|"
  it "rm completes projects, not worktrees"
  assert_eq "$(zc "cx rm web1:api")" "projects web1:api - idle|"
  it "stop offers the live sessions, and no servers"
  assert_eq "$(zc "cx stop ")" "projects web1:api  idle|"
  it "wt add completes project/"
  has "$(zc "cx wt add web1:")" "projects web1:api/  project"
done

describe "the oh-my-zsh plugin"

export CX_ZTEST_MODE=omz
it "completes cx"
has "$(zc "cx open web1:api@")" "sessions web1:api@review - working"
it "defines the aliases, and they complete as the command they stand for"
has "$(zc "cxo web1:api@")" "sessions web1:api@review - working"
it "zstyle ... aliases no leaves them out"
assert_eq "$(zsh -fc "zstyle ':omz:plugins:cx' aliases no; source '$ROOT/completions/omz/cx/cx.plugin.zsh'; alias cxo")" ""

it "copied without its _cx, falls back to cx completion zsh"
mkdir -p "$TMP/plugins" "$TMP/bin" "$TMP/omzcache"
cp -RP "$ROOT/completions/omz/cx" "$TMP/plugins/cx" # _cx now dangles
ln -s "$ROOT/bin/cx" "$TMP/bin/cx"
out=$(PATH="$TMP/bin:$PATH" ZSH_CACHE_DIR="$TMP/omzcache" CX_ZTEST_PLUGIN="$TMP/plugins/cx" \
  zc "cx open web1:api@")
has "$out" "sessions web1:api@review - working"
it "writing it once into oh-my-zsh's completion cache"
assert_ok test -s "$TMP/omzcache/completions/_cx"

describe "without any cache or server"

export CX_ZTEST_MODE=fpath

rm -rf "$CX_CACHE_DIR" "$CX_SSHD_DIR"
it "offers nothing, rather than an empty candidate"
assert_eq "$(zc "cx open ")" ""
it "still completes commands"
has "$(zc "cx st")" "commands status -"

summary
