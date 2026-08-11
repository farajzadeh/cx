#!/usr/bin/env bash
# test/run.sh — the whole test suite.
#
#   ./test/run.sh              lint + unit tests on this machine's bash
#   ./test/run.sh --bash32     also re-run everything under real bash 3.2
#   ./test/run.sh --integration  also run tests needing Docker SSH nodes
#   ./test/run.sh --all        everything
#
# --bash32 is the one that matters most. Developers run modern bash; macOS
# users run 3.2. Docker gives us the real interpreter rather than a guess
# about which constructs are safe.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT" || exit 1

RUN_BASH32=0
RUN_INTEGRATION=0
for arg in "$@"; do
  case "$arg" in
    --bash32) RUN_BASH32=1 ;;
    --integration) RUN_INTEGRATION=1 ;;
    --all)
      RUN_BASH32=1
      RUN_INTEGRATION=1
      ;;
    -h | --help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n' "$arg" >&2
      exit 64
      ;;
  esac
done

fail=0

hdr() {
  printf '\n\033[1;4m%s\033[0m\n' "$1"
}

# --- lint ------------------------------------------------------------------

hdr "Portability lint"
./test/lint-portability.sh || fail=1

if command -v shellcheck >/dev/null 2>&1; then
  hdr "shellcheck"
  # SC1091: sourced paths are resolved at runtime, not statically.
  if find . -path ./.git -prune -o -type f \
    \( -name '*.sh' -o -name 'cx' -o -name 'cx-agent' \) -print0 |
    xargs -0 shellcheck -x -e SC1091 -S warning; then
    printf '\033[32m✓ shellcheck clean\033[0m\n'
  else
    fail=1
  fi
else
  printf '\n\033[33m- shellcheck not installed, skipping\033[0m\n'
  printf '  install: apt install shellcheck | brew install shellcheck\n'
fi

# --- unit ------------------------------------------------------------------

hdr "Unit tests (bash ${BASH_VERSION%%(*})"
for t in test/unit/*.test.sh; do
  [ -e "$t" ] || continue
  printf '\n\033[2m%s\033[0m\n' "$t"
  bash "$t" || fail=1
done

# --- bash 3.2 --------------------------------------------------------------

if [ "$RUN_BASH32" -eq 1 ]; then
  hdr "Unit tests under bash 3.2 (macOS's version)"
  if command -v docker >/dev/null 2>&1; then
    for t in test/unit/*.test.sh; do
      [ -e "$t" ] || continue
      printf '\n\033[2m%s (bash 3.2)\033[0m\n' "$t"
      docker run --rm -v "$ROOT":/w -w /w bash:3.2 bash "$t" || fail=1
    done
  else
    printf '\033[31m✗ docker not available; cannot verify bash 3.2\033[0m\n'
    fail=1
  fi
fi

# --- integration -----------------------------------------------------------

if [ "$RUN_INTEGRATION" -eq 1 ]; then
  hdr "Integration tests (Docker)"
  for t in test/integration/*.test.sh; do
    [ -e "$t" ] || continue
    printf '\n\033[2m%s\033[0m\n' "$t"
    bash "$t" || fail=1
  done
fi

# --- summary ---------------------------------------------------------------

printf '\n'
if [ "$fail" -eq 0 ]; then
  printf '\033[1;32m✓ all suites passed\033[0m\n'
else
  printf '\033[1;31m✗ failures above\033[0m\n'
fi
exit "$fail"
