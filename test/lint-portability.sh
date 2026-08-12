#!/usr/bin/env bash
# test/lint-portability.sh — reject bash-4 and GNU-only constructs.
#
# This runs in CI ahead of the test suite. It catches the class of bug that is
# invisible on the developer's machine (modern bash, GNU coreutils) and only
# surfaces as an issue report from a macOS user. Grep is a blunt instrument,
# but these patterns have no legitimate use in this codebase, so false
# positives are cheap to resolve and false negatives are what cost us.
#
# Scope: everything that runs on a user's machine. Test files are exempt from
# some rules where they legitimately exercise the forbidden thing.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT" || exit 1

fail=0

# Files that must run on bash 3.2 / BSD userland.
#
# This file is excluded from its own scan: it necessarily contains every
# pattern it forbids, as string literals.
targets() {
  find . \
    -path ./.git -prune -o \
    -type f \
    \( -name '*.sh' -o -name 'cx' -o -name 'cx-agent' \) \
    -print | grep -v 'lint-portability.sh' | sort
}

# check PATTERN DESCRIPTION
#
# Two exemptions, both required rather than convenient:
#   - comment lines, so docs and headers can name what they forbid
#   - lines marked `# portable-ok: reason`, for the handful of places that
#     deliberately use the raw construct — chiefly compat.sh, which cannot
#     shim `stat -c` without probing for it first
check() {
  local pattern="$1" desc="$2" hits
  hits=$(targets | while IFS= read -r f; do
    grep -nE "$pattern" "$f" 2>/dev/null |
      grep -vE '^[0-9]+:[[:space:]]*#' |
      grep -v 'portable-ok' |
      sed "s|^|$f:|"
  done)
  if [ -n "$hits" ]; then
    printf '\033[31m✗ %s\033[0m\n' "$desc"
    printf '%s\n' "$hits" | sed 's/^/    /'
    fail=1
  else
    printf '\033[32m✓\033[0m %s\n' "$desc"
  fi
}

echo "Portability lint (bash 3.2 / BSD userland)"
echo

check 'declare[[:space:]]+-[A-Za-z]*A' 'no associative arrays (bash 4)'
check '\b(mapfile|readarray)\b' 'no mapfile/readarray (bash 4)'
check '\$\{[A-Za-z_][A-Za-z0-9_]*\^\^|\$\{[A-Za-z_][A-Za-z0-9_]*,,' 'no ${var^^} / ${var,,} (bash 4)'
check '\bwait[[:space:]]+-n\b' 'no wait -n (bash 4.3)'
check '\bcoproc\b' 'no coproc (bash 4)'
check 'shopt[[:space:]]+-s[[:space:]]+globstar' 'no globstar (bash 4)'
check '\bflock\b' 'no flock (Linux only) — use cx_lock_acquire'
check '\bsed[[:space:]]+-i\b' 'no sed -i (GNU/BSD syntax differs) — use cx_write_atomic'
check '\bgrep[[:space:]]+(-[a-zA-Z]*)?P\b' 'no grep -P (not in BSD grep)'
check '\bsort[[:space:]]+(-[a-zA-Z]*)?V\b' 'no sort -V (not in older BSD sort)'
check '\btimeout[[:space:]]+[0-9]' 'no timeout(1) (GNU coreutils) — use ssh ConnectTimeout'
check '\bsetsid\b' 'no setsid (Linux only) — use cx_bg'
check '\bstat[[:space:]]+-c\b' 'no bare stat -c (GNU only) — use cx_mtime'
check '\brealpath[[:space:]]' 'no realpath(1) (absent on older macOS) — use cx_realpath'
check '\breadlink[[:space:]]+-f\b' 'no readlink -f (GNU only) — use cx_realpath'
check '\b(md5sum|sha1sum|sha256sum)\b' 'no GNU digest tools — use cx_sanitize'
check '\becho[[:space:]]+-e\b' 'no echo -e (not portable) — use printf'
check '\bseq[[:space:]]' 'no seq(1) — use a while loop or brace range'

# `set -u` plus an empty array is an unbound-variable error on bash 3.2.
# The safe idiom is "${arr[@]+"${arr[@]}"}".
#
# The leading (^|[^+]) is load-bearing: the safe idiom CONTAINS a bare
# "${arr[@]}" as its inner half, and without the guard this rule fires on
# every correct use of the thing it is telling you to write. What
# distinguishes the two is the `+` immediately before the inner quote.
# The trailing ([^+]|$) catches a bad expansion at end of line.
check '(^|[^+])"\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\}"([^+]|$)' 'expand arrays as "${arr[@]+"${arr[@]}"}" (bash 3.2 + set -u)'

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32mportability lint clean\033[0m\n'
else
  printf '\033[31mportability lint failed\033[0m\n'
fi
exit "$fail"
