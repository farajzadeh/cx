#!/usr/bin/env bash
# Run what the docs promise, against a real server, and report mismatches.
#
# Not a grep of the docs: a check of the behaviours they claim. Each case names
# where the claim comes from, so a failure says which sentence is wrong.

# The host and project are overridable so this runs against anyone's setup:
#   CX_AUDIT_HOST=web1 ./test/doc-audit.sh
#
# It needs a REAL server with Claude Code signed in, which is why it is not in
# test/run.sh: it starts sessions and spends tokens. Run it when the docs
# change, or before a release.
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CX="${CX_AUDIT_CX:-$ROOT/bin/cx}"
H="${CX_AUDIT_HOST:-local}"
P="${CX_AUDIT_PROJECT:-docaudit}"
T="$H:$P"
pass=0
fail=0
skip=0
ok() {
  pass=$((pass + 1))
  printf '  \033[32mok\033[0m   %s\n' "$1"
}
no() {
  fail=$((fail + 1))
  printf '  \033[31mFAIL\033[0m %s\n     %s\n' "$1" "$2"
}
sk() {
  skip=$((skip + 1))
  printf '  \033[33m--\033[0m   %s (%s)\n' "$1" "$2"
}
grp() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# rc CODE CMD... — the documented exit code
rc() {
  local want="$1"
  shift
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  [ "$got" = "$want" ] && ok "$* -> $want" || no "$*" "expected exit $want, got $got"
}
# out PATTERN CMD... — output must contain PATTERN
out() {
  local pat="$1"
  shift
  local o
  o=$("$@" 2>&1)
  case "$o" in *"$pat"*) ok "$* ~ '$pat'" ;; *) no "$*" "missing '$pat' in: $(printf '%s' "$o" | head -2 | tr '\n' ' ')" ;; esac
}
# js FILTER EXPECT CMD... — --json output through jq must equal EXPECT
js() {
  local f="$1" want="$2"
  shift 2
  local got
  got=$("$@" 2>/dev/null | jq -r "$f" 2>/dev/null)
  [ "$got" = "$want" ] && ok "$* | jq $f == $want" || no "$*" "jq $f gave '$got', expected '$want'"
}

grp "every command answers --help, exits 0, and names itself"
for c in host provision login doctor new ls rm wt worktree open resume shell \
  code ask peek nudge goal driver status stop cache; do
  o=$("$CX" "$c" --help 2>&1)
  r=$?
  if [ "$r" != 0 ]; then
    no "cx $c --help" "exit $r"
  elif [ "${#o}" -lt 80 ]; then
    no "cx $c --help" "only ${#o} chars of help"
  else ok "cx $c --help (${#o} chars)"; fi
done

grp "top-level contract (README: Commands)"
out "multi-server" "$CX" --help
out "." "$CX" --version
rc 3 "$CX" no-such-command
rc 0 "$CX" --version

grp "global flags are accepted before AND after the subcommand (CLAUDE.md)"
rc 0 "$CX" --json ls
rc 0 "$CX" ls --json
js '(.servers|length)>0' true "$CX" --json ls

grp "read-only commands run (README)"
rc 0 "$CX" ls
rc 0 "$CX" status
rc 0 "$CX" doctor
rc 0 "$CX" peek
rc 0 "$CX" cache status
rc 0 "$CX" host ls
rc 0 "$CX" wt ls
rc 0 "$CX" goal ls
rc 0 "$CX" driver

grp "exit codes (docs/ARCHITECTURE.md: Exit codes)"
rc 2 "$CX" ls no-such-host
rc 2 "$CX" open "no-such-host:x"
rc 3 "$CX" open
rc 3 "$CX" nudge
rc 3 "$CX" goal

grp "the target grammar (README: Targets)"
"$CX" -y rm "$T" --purge >/dev/null 2>&1
rc 0 "$CX" new "$T"
rc 4 "$CX" new "$T"
out "$P" "$CX" ls "$H"
# A worktree needs a commit to branch from, and cx says so rather than letting
# git's "invalid reference" out. The docs did not mention this until an audit
# ran the documented sequence and hit it.
out "no commits yet" "$CX" wt add "$T/authfix"
$CX shell "$T" >/dev/null 2>&1 || true
ssh "$H" "cd ~/projects/$P && git -c user.email=a@b -c user.name=a commit -q --allow-empty -m init" >/dev/null 2>&1
rc 0 "$CX" wt add "$T/authfix"
out "authfix" "$CX" wt ls "$H:$P"
rc 0 "$CX" wt rm "$T/authfix" --force

grp "goals (README: Definitions of done)"
printf 'the tests pass' | "$CX" goal new docaudit-goal --member "$P" >/dev/null 2>&1
js '.dod' 'the tests pass' "$CX" --json goal show docaudit-goal
js '.state' 'active' "$CX" --json goal show docaudit-goal
printf 'the tests pass and it ships' | "$CX" goal dod docaudit-goal >/dev/null 2>&1
js '.revisions|length' '1' "$CX" --json goal show docaudit-goal
js '.revisions[0].from' 'the tests pass' "$CX" --json goal show docaudit-goal
"$CX" goal pause docaudit-goal >/dev/null 2>&1
js '.state' 'paused' "$CX" --json goal show docaudit-goal
"$CX" goal resume docaudit-goal >/dev/null 2>&1
js '.state' 'active' "$CX" --json goal show docaudit-goal
rc 2 "$CX" goal show no-such-goal

grp "open -d and peek (README: Letting them run themselves)"
rc 0 "$CX" open -d --dangerously-skip-permissions "$T@t1"
sleep 12
out "$P@t1" "$CX" peek "$T"
js "([.sessions[].target]|sort|join(\",\"))" "$P,$P@t1" "$CX" --json peek "$T"

grp "nudge (README) — declines and delivers"
js '.sent' 'false' "$CX" --json nudge "$T@nosuch" hello
js '.reason' 'dead' "$CX" --json nudge "$T@nosuch" hello
rc 0 "$CX" nudge "$T@nosuch" hello
out "sent to" "$CX" nudge "$T@t1" "Reply with exactly DOCAUDIT-OK and nothing else."
sleep 14
out "DOCAUDIT-OK" tmux capture-pane -pJ -S -200 -t "=cx-$P@t1:"

grp "ask (README) — and the two-writer refusal"
out "PONG" "$CX" ask "$T" "reply with exactly PONG and nothing else"
rc 4 "$CX" ask "$T@t1" "hi"
rc 3 "$CX" shell "$T" --permission-mode plan

grp "cache (README: Cache)"
rc 0 "$CX" cache refresh "$H"
out "$H" "$CX" cache status
rc 0 "$CX" cache clear "$H"

grp "cleanup"
"$CX" goal rm docaudit-goal -y >/dev/null 2>&1 || printf 'y\n' | "$CX" goal rm docaudit-goal >/dev/null 2>&1
rc 0 "$CX" -y stop "$T" --all
rc 0 "$CX" -y rm "$T" --purge

printf '\n\033[1m%s passed, %s failed, %s skipped\033[0m\n' "$pass" "$fail" "$skip"
[ "$fail" = 0 ]
