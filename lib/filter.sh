#!/usr/bin/env bash
# lib/filter.sh — the pieces `cx ls`, `cx host ls` and `cx wt ls` share for
# narrowing a listing: a pattern matcher and a duration parser.
#
# The matcher is written in jq, not shell, because every listing is already
# formatted in one jq (see "ONE jq for the whole table" in lib/cmd/ls.sh) and
# a shell-side matcher would mean a process per row. CX_FILTER_JQ is a string
# of jq definitions a caller prepends to its own program; cx_filter_test runs
# it on its own so a unit test can pin the semantics.

[ -n "${_CX_FILTER_LOADED:-}" ] && return 0
_CX_FILTER_LOADED=1

# Pattern semantics, identical everywhere:
#
#   - case-insensitive;
#   - a pattern without `*` matches anywhere in the field (a substring);
#   - a pattern with `*` is a glob over the WHOLE field, so `api*` means
#     "starts with api" and `*fix` "ends with fix". Only `*` is special: `?`,
#     `[` and `.` are literal, because project and branch names contain dots
#     and a pattern someone pastes from a branch name must mean what it says.
#
# The glob is matched by splitting rather than by regex. Converting to a regex
# would need every metacharacter escaped first, and jq's regex support (and
# its string `index`, which returns byte offsets in 1.6) is the least portable
# part of jq across the versions servers and laptops actually have.
#
# shellcheck disable=SC2016  # jq program text: $vars are jq's, not the shell's
CX_FILTER_JQ='
def _cx_glob($parts):
  . as $s
  | ($parts | length) as $n
  | if $n == 1 then $s == $parts[0]
    elif ($s | length) < (($parts[0] | length) + ($parts[$n - 1] | length)) then false
    elif ($s | startswith($parts[0]) | not) then false
    elif ($s | endswith($parts[$n - 1]) | not) then false
    else
      reduce ($parts[1:$n - 1][] | select(. != "")) as $q
        ({ok: true,
          rest: $s[($parts[0] | length):(($s | length) - ($parts[$n - 1] | length))]};
         if .ok | not then .
         else (.rest | split($q)) as $bits
           | if ($bits | length) < 2 then {ok: false}
             else {ok: true, rest: ($bits[1:] | join($q))}
             end
         end)
      | .ok
    end;
# STRING | cx_match(PATTERN) — does this one field match? null never does.
def cx_match($pat):
  if . == null then false
  else (tostring | ascii_downcase) as $s
    | ($pat | ascii_downcase) as $p
    | if ($p | contains("*")) then $s | _cx_glob($p | split("*"))
      else $s | contains($p)
      end
  end;
# [FIELDS] | cx_any(PATTERN) — does any of them? An empty pattern always does.
def cx_any($pat): if $pat == "" then true else any(.[]; cx_match($pat)) end;
'

# cx_filter_test PATTERN STRING — exit 0 when STRING matches PATTERN.
# The same definitions every listing uses, for a test (or a script) to call.
cx_filter_test() {
  jq -en --arg p "$1" --arg s "$2" "$CX_FILTER_JQ"' $s | cx_match($p)' >/dev/null
}

# cx_duration_secs DUR — "90", "90s", "30m", "2h", "7d", "2w" as seconds.
#
# Returns 3 (usage) on anything else, so a caller can pass the code straight
# through: `--idle 2x` is a typo to report, not a filter that matches nothing.
cx_duration_secs() {
  local d="${1:-}" n unit
  case "$d" in
    '' | *[!0-9smhdw]*) return 3 ;;
  esac
  n="${d%[smhdw]}"
  unit="${d#"$n"}"
  case "$n" in
    '' | *[!0-9]*) return 3 ;;
  esac
  # Strip leading zeros: bash arithmetic reads 010 as octal, and 08 as an error.
  while [ "${#n}" -gt 1 ] && [ "${n#0}" != "$n" ]; do n="${n#0}"; done
  case "$unit" in
    '' | s) printf '%s' "$n" ;;
    m) printf '%s' $((n * 60)) ;;
    h) printf '%s' $((n * 3600)) ;;
    d) printf '%s' $((n * 86400)) ;;
    w) printf '%s' $((n * 604800)) ;;
  esac
}

# cx_filter_split_list LIST... — "a,b" "c" -> one item per line, empties dropped.
# For flags that are both repeatable and comma-separated, like --host.
cx_filter_split_list() {
  local a
  for a in "$@"; do
    printf '%s\n' "$a" | tr ',' '\n'
  done | awk 'NF { print }'
}
