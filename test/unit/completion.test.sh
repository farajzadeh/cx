#!/usr/bin/env bash
# Unit tests for completions/cx.bash.
#
# Drives _cx the way readline does: COMP_LINE and COMP_POINT for the line, and
# COMP_WORDS split on COMP_WORDBREAKS — which by default contains ':' and '@',
# so `web1:api@re` arrives as five words. Getting that wrong is the classic
# completion bug (`cx open web1:web1:api`), and it only shows up with the
# splitting reproduced faithfully, so split() below does exactly that.
#
# Everything is read from fixture files: completion does no network work.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=../harness.sh
. "$ROOT/test/harness.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cx-comp.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export CX_CACHE_DIR="$TMP/cache" CX_SSHD_DIR="$TMP/ssh.d" CX_SSH_CONFIG="$TMP/ssh_config"
mkdir -p "$CX_CACHE_DIR" "$CX_SSHD_DIR"
: >"$CX_SSHD_DIR/web1.conf"
: >"$CX_SSHD_DIR/web2.conf"
: >"$CX_SSHD_DIR/web3.conf" # a server with no projects cached

printf '%s\n' web1:api web1:api/authfix web1:blog web2:dash >"$CX_CACHE_DIR/targets"
printf 'web1:api\tidle\nweb1:api@review\tworking\nweb1:api/authfix@tests\tblocked\nweb2:dash\tdead\n' \
  >"$CX_CACHE_DIR/state"
printf 'web1\tauth\tactive\nweb1\tdocs\tpaused\nweb2\tauth\tactive\n' >"$CX_CACHE_DIR/goals"
printf 'Host gpu\n  HostName 10.0.0.9\nHost *.internal !bad\nHost box1 box2\n' >"$CX_SSH_CONFIG"

# shellcheck source=../../completions/cx.bash
. "$ROOT/completions/cx.bash"

DEFAULT_BREAKS=$(printf ' \t\n"'"'"'@><=;|&(:')

# split LINE — COMP_WORDS / COMP_CWORD as readline builds them: words on
# whitespace, and each run of break characters a word of its own.
split() {
  local line="$1" brk="${COMP_WORDBREAKS-}" rest word run c cls pcls
  COMP_WORDS=()
  rest="$line"
  while :; do
    rest="${rest#"${rest%%[![:space:]]*}"}"
    [ -n "$rest" ] || break
    word="${rest%%[[:space:]]*}"
    rest="${rest#"$word"}"
    # A new word starts wherever the text switches between break characters
    # and anything else.
    run=""
    pcls=""
    while [ -n "$word" ]; do
      c="${word%"${word#?}"}"
      word="${word#?}"
      cls=n
      case "$c" in [:@]) case "$brk" in *"$c"*) cls=b ;; esac ;; esac
      if [ -n "$run" ] && [ "$cls" != "$pcls" ]; then
        COMP_WORDS[${#COMP_WORDS[@]}]="$run"
        run=""
      fi
      run="$run$c"
      pcls=$cls
    done
    COMP_WORDS[${#COMP_WORDS[@]}]="$run"
  done
  case "$line" in
    *[[:space:]]) COMP_WORDS[${#COMP_WORDS[@]}]="" ;;
  esac
  COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
}

# comp LINE — complete at the end of LINE; prints COMPREPLY sorted, '|' after each.
comp() {
  COMP_LINE="$1"
  COMP_POINT=${#1}
  split "$1"
  COMPREPLY=()
  _cx
  [ "${#COMPREPLY[@]}" -gt 0 ] || return 0
  printf '%s\n' "${COMPREPLY[@]+"${COMPREPLY[@]}"}" | sort | tr '\n' '|'
}

has() {
  case "|$1" in
    *"|$2|"*) _t_ok "$_T_NAME" ;;
    *) _t_no "$_T_NAME" "missing: [$2]" "in:      [$1]" ;;
  esac
}
lacks() {
  case "|$1" in
    *"|$2|"*) _t_no "$_T_NAME" "should not offer: [$2]" "in: [$1]" ;;
    *) _t_ok "$_T_NAME" ;;
  esac
}

COMP_WORDBREAKS="$DEFAULT_BREAKS"

describe "the test's own word splitting matches readline's"

it "breaks a target at ':' and '@'"
split "cx open web1:api@re"
assert_eq "${COMP_WORDS[*]}" "cx open web1 : api @ re"
it "keeps the break as the current word when the line ends on one"
split "cx open web1:"
assert_eq "$COMP_CWORD:${COMP_WORDS[COMP_CWORD]}" "3::"

describe "subcommands"

out=$(comp "cx ")
for c in open bar tabs jump forget peek nudge goal completion driver find; do
  it "offers $c"
  has "$out" "$c "
done

it "offers the global flags before a subcommand"
has "$(comp "cx --")" "--no-cache "

describe "global flags do not move the subcommand"

it "cx --json <TAB> still offers subcommands"
has "$(comp "cx --json ")" "ls "
it "cx --json ls <TAB> completes ls's argument (a host)"
assert_eq "$(comp "cx --json ls ")" "web1 |web2 |web3 |"
it "cx -r -y open <TAB> completes targets"
has "$(comp "cx -r -y open ")" "web1:api"
it "cx ls --no-color --stale w<TAB>"
assert_eq "$(comp "cx ls --no-color --stale w")" "web1 |web2 |web3 |"

describe "targets: host:project[/worktree][@label]"

it "lists each project once, host-qualified, and hosts with none as host:"
assert_eq "$(comp "cx open ")" "web1:api|web1:blog |web2:dash |web3:|"
it "a project with worktrees or sessions ends without a space, to descend"
has "$(comp "cx open web1:a")" "api"
it "strips everything up to the colon, since bash replaces only after it"
assert_eq "$(comp "cx open web1:")" "api|blog |"
it "descends into a project's worktrees and sessions once it is typed"
assert_eq "$(comp "cx open web1:api")" "api|api/authfix|api@review |"
it "completes @label after the '@' break"
assert_eq "$(comp "cx open web1:api@")" "review |"
it "completes a worktree's own sessions"
assert_eq "$(comp "cx open web1:api/authfix@")" "tests |"
it "completes a worktree after the slash"
assert_eq "$(comp "cx open web1:api/")" "api/authfix|"
it "completes a bare project name"
assert_eq "$(comp "cx open bl")" "blog |"
it "completes a bare project's children"
has "$(comp "cx open api")" "api@review "

describe "targets when ':' and '@' are not word breaks"

COMP_WORDBREAKS=$(printf ' \t\n"'"'"'><=;|&(')
it "returns whole targets"
assert_eq "$(comp "cx open web1:b")" "web1:blog |"
it "returns whole @label targets"
assert_eq "$(comp "cx open web1:api@")" "web1:api@review |"
COMP_WORDBREAKS="$DEFAULT_BREAKS"

describe "which commands complete which targets"

it "new completes only host:"
assert_eq "$(comp "cx new ")" "web1:|web2:|web3:|"
it "wt add completes host:project/ for a worktree that does not exist yet"
assert_eq "$(comp "cx wt add web1:")" "api/|blog/|"
it "wt rm completes worktrees, not session labels"
assert_eq "$(comp "cx worktree rm web1:api")" "api|api/authfix |"
it "stop prefers live sessions and never offers a dead one"
assert_eq "$(comp "cx stop ")" "web1:api|"
it "a server with nothing running offers nothing, rather than everything"
assert_eq "$(comp "cx stop web2:")" ""
it "stop descends into the live sessions of a project"
assert_eq "$(comp "cx stop web1:api")" "api|api/authfix|api@review |"
it "nudge offers the same live sessions"
has "$(comp "cx nudge web1:api@")" "review "
it "rm completes projects only"
assert_eq "$(comp "cx rm web1:")" "api |blog |"
it "code completes units without labels"
lacks "$(comp "cx code web1:api")" "api@review "
it "ask completes only its first argument"
assert_eq "$(comp "cx ask web1:api ")" ""
it "provision, login and doctor complete hosts"
assert_eq "$(comp "cx provision --all w")" "web1 |web2 |web3 |"
it "wt ls completes hosts and host:project"
has "$(comp "cx wt ls ")" "web2 "

mv "$CX_CACHE_DIR/state" "$CX_CACHE_DIR/state.away"
it "stop falls back to every target when cx has not looked at sessions yet"
assert_eq "$(comp "cx stop ")" "web1:api|web1:blog |web2:dash |web3:|"
mv "$CX_CACHE_DIR/state.away" "$CX_CACHE_DIR/state"

describe "subverbs"

it "wt"
assert_eq "$(comp "cx wt ")" "add |ls |rm |"
it "host"
has "$(comp "cx host ")" "import "
it "cache"
assert_eq "$(comp "cx cache ")" "clear |refresh |status |"
it "goal"
has "$(comp "cx goal ")" "on-stop "
it "goal --host takes a value, so the next word is still the subverb"
has "$(comp "cx goal --host web1 ")" "show "
it "completion offers the shells"
assert_eq "$(comp "cx completion ")" "bash |fish |zsh |"

describe "per-command flags"

out=$(comp "cx open --")
it "open offers --dangerously-skip-permissions"
has "$out" "--dangerously-skip-permissions "
it "open offers --no-hooks"
has "$out" "--no-hooks "
it "and the global flags"
has "$out" "--json "
it "flag values are not shown with their kind"
lacks "$out" "--model=model "
it "bar offers --icons but not open's flags"
out=$(comp "cx bar --")
has "$out" "--icons "
lacks "$out" "--dangerously-skip-permissions "
it "stop offers --all"
has "$(comp "cx stop web1:api --")" "--all "
it "wt add offers --branch and --open"
out=$(comp "cx wt add web1:api/x --")
has "$out" "--branch "
has "$out" "--open "
it "new offers --open"
has "$(comp "cx new web1:x --")" "--open "
it "find offers --print"
has "$(comp "cx find --")" "--print "
it "tabs offers --take"
has "$(comp "cx tabs --")" "--take "
it "goal ls offers --state"
has "$(comp "cx goal ls --")" "--state "

describe "flag values"

it "--permission-mode"
has "$(comp "cx open web1:api --permission-mode ")" "acceptEdits "
it "--effort"
assert_eq "$(comp "cx ask web1:api --effort h")" "high |"
it "--icons"
assert_eq "$(comp "cx bar --icons n")" "nerd |"
it "--states completes the last element of a list"
assert_eq "$(comp "cx jump --states blocked,i")" "blocked,idle |"
it "a flag's value is not taken as the target"
assert_eq "$(comp "cx open --model opus w")" "web1:api|web1:blog |web2:dash |web3:|"
it "--window completes targets"
has "$(comp "cx bar --window web1:api@")" "review "
it "--host completes hosts"
assert_eq "$(comp "cx goal --host w")" "web1 |web2 |web3 |"
it "free-text values offer nothing"
assert_eq "$(comp "cx new web1:x --repo ")" ""
it "nothing after -- — that belongs to Claude Code"
assert_eq "$(comp "cx open web1:api -- ")" ""

describe "names from local caches"

it "host rm completes host aliases"
assert_eq "$(comp "cx host rm ")" "web1 |web2 |web3 |"
it "host import completes ~/.ssh/config hosts, not patterns"
assert_eq "$(comp "cx host import ")" "box1 |box2 |gpu |"
it "goal show completes goal names, once each"
assert_eq "$(comp "cx goal show ")" "auth |docs |"
it "peek --goal completes goal names"
has "$(comp "cx peek --goal d")" "docs "
it "goal member completes add|rm, then the goal, then a target"
assert_eq "$(comp "cx goal member ")" "add |rm |"
assert_eq "$(comp "cx goal member add a")" "auth |"
has "$(comp "cx goal member add auth web1:api@")" "review "

describe "the goal-name cache that feeds it"

(
  # shellcheck source=../../lib/compat.sh
  . "$ROOT/lib/compat.sh"
  # shellcheck source=../../lib/cache.sh
  . "$ROOT/lib/cache.sh"
  printf 'auth\tactive\nnew-api\tpaused\n' | cx_goals_write web1
  cx_goals_add web2 perf
  cx_goals_drop web1 docs
  cx_goals_add web1 auth # already there: not duplicated
)
it "a listing replaces one host's goals, and the others are kept"
assert_eq "$(sort "$CX_CACHE_DIR/goals" | tr '\t\n' ' |')" \
  "web1 auth active|web1 new-api paused|web2 auth active|web2 perf active|"
it "and completion sees the result"
assert_eq "$(comp "cx goal rm ")" "auth |new-api |perf |"

describe "without any cache"

rm -rf "$CX_CACHE_DIR"
it "still offers hosts, and does not fail"
assert_eq "$(comp "cx open ")" "web1:|web2:|web3:|"
it "offers no goal names rather than an error"
assert_eq "$(comp "cx goal show ")" ""

summary
