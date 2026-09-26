# bash completion for cx
#
#   eval "$(cx completion bash)"          or source this file, or drop it in
#   ~/.local/share/bash-completion/completions/cx
#
# NO NETWORK WORK, EVER — not even a background refresh. Tab must never hang on
# an unreachable server, and a slightly stale list is a far better failure than
# a frozen shell. Everything here reads local files that cx keeps as a side
# effect of commands the user ran anyway:
#
#   ~/.cache/cx/targets     host:project and host:project/worktree, per listing
#   ~/.cache/cx/state       host:target<TAB>state, per cx peek or cx bar
#   ~/.cache/cx/goals       host<TAB>goal<TAB>state, per cx goal ls
#   ~/.config/cx/ssh.d/     one <alias>.conf per server
#
# Targets bash 3.2 (macOS) with or without the bash-completion package, which
# is why there is no compopt and no _get_comp_words_by_ref below.
#
# TO ADD A FLAG OR A SUBCOMMAND, edit the tables — _cx_commands, _cx_subverbs,
# _cx_flags and _cx_positional. Nothing else needs to know.

# ---------------------------------------------------------------------------
# Tables
# ---------------------------------------------------------------------------

_cx_commands="host provision login doctor new ls rm wt worktree open resume shell code ask status stop forget peek nudge bar tabs jump goal driver cache completion find pick help version"

# Valid anywhere in the argv: bin/cx strips them before choosing a subcommand.
_cx_global_flags="-r --refresh --no-cache --stale --json -y --yes --no-color"

# _cx_subverbs CMD — the second word, for commands that have one.
_cx_subverbs() {
  case "$1" in
    host) printf '%s' "add import ls test edit rm" ;;
    wt) printf '%s' "add ls rm" ;;
    goal) printf '%s' "new ls show dod member pause resume done log on-stop rm" ;;
    cache) printf '%s' "status clear refresh" ;;
  esac
}

# _cx_flags CMD [SUB] — the command's own flags, one line per command.
#
# "--name" is a switch; "--name=KIND" takes a value, completed as KIND (see
# _cx_values). KIND "word" means free text: nothing is offered, but the scanner
# still knows the next word is a value rather than a positional argument.
_cx_flags() {
  case "$1${2:+ $2}" in
    "host add") printf '%s' "--alias=word --hostname=word --user=word --port=word --identity=file --root=word --no-test" ;;
    "host import") printf '%s' "--root=word" ;;
    provision) printf '%s' "--all -a" ;;
    new) printf '%s' "--repo=word --root=word --open -d --detach" ;;
    ls) printf '%s' "--git" ;;
    rm) printf '%s' "--purge" ;;
    "wt add") printf '%s' "--branch=word --from=word --open -d --detach" ;;
    "wt rm") printf '%s' "--force --merged" ;;
    open | resume) printf '%s' "-d --detach --no-hooks --permission-mode=permmode --dangerously-skip-permissions --model=model --effort=effort" ;;
    shell) printf '%s' "-d --detach --no-hooks" ;;
    ask) printf '%s' "--permission-mode=permmode --dangerously-skip-permissions --model=model --effort=effort --output-format=outfmt --json-schema=word --max-budget-usd=word" ;;
    stop) printf '%s' "--all" ;;
    peek) printf '%s' "--all --tail=word --goal=goal" ;;
    nudge) printf '%s' "--force" ;;
    bar) printf '%s' "--setup --plain --attached --color --icons=icons --window=all --max=word --states=states --label=word" ;;
    tabs) printf '%s' "-n --dry-run --no-attach --take -s --session=word" ;;
    jump) printf '%s' "--states=states" ;;
    find | pick) printf '%s' "--print" ;;
    goal | "goal "*)
      printf '%s' "--host=host"
      case "${2:-}" in
        new) printf '%s' " --member=all" ;;
        ls) printf '%s' " --state=goalstate" ;;
        log) printf '%s' " --event=word --target=all" ;;
        on-stop) printf '%s' " --max=word --model=model --off" ;;
      esac
      ;;
  esac
}

# _cx_positional CMD SUB N — what the Nth plain argument after CMD [SUB] is.
#
# Target kinds (see _cx_targets): all · units (no @label) · projects · live
# (running sessions, preferred for stop/nudge) · known (anything in the state
# cache) · hostcolon (host: only) · projslash (host:project/, for a worktree
# that does not exist yet) · hostproj (a host or a host:project).
_cx_positional() {
  case "$1${2:+ $2}:$3" in
    "host test:1" | "host edit:1" | "host rm:1") printf host ;;
    "host import:1") printf sshhost ;;
    provision:* | login:1 | doctor:1 | ls:1) printf host ;;
    "cache clear:1" | "cache refresh:1") printf host ;;
    new:1) printf hostcolon ;;
    rm:1) printf projects ;;
    "wt add:1") printf projslash ;;
    "wt ls:1") printf hostproj ;;
    "wt rm:1" | code:1) printf units ;;
    open:1 | resume:1 | shell:1 | ask:1 | peek:1 | find:1 | pick:1) printf all ;;
    stop:1 | nudge:1) printf live ;;
    forget:1) printf known ;;
    completion:1) printf shell ;;
    "goal show:1" | "goal dod:1" | "goal pause:1" | "goal resume:1" | "goal done:1") printf goal ;;
    "goal log:1" | "goal on-stop:1" | "goal rm:1" | "goal member:2") printf goal ;;
    "goal member:1") printf memberop ;;
    "goal member:3") printf all ;;
  esac
}

# Spellings the commands accept, folded to the one the tables use.
_cx_norm_cmd() {
  case "$1" in
    worktree) printf wt ;;
    *) printf '%s' "$1" ;;
  esac
}
_cx_norm_sub() {
  case "$1" in
    new) if [ "$2" = wt ]; then printf add; else printf new; fi ;;
    list) printf ls ;;
    remove | delete) printf rm ;;
    check) printf test ;;
    clean | purge) printf clear ;;
    *) printf '%s' "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Local sources — files only
# ---------------------------------------------------------------------------

_cx_cache_dir() { printf '%s' "${CX_CACHE_DIR:-$HOME/.cache/cx}"; }
_cx_targets_file() { printf '%s/targets' "$(_cx_cache_dir)"; }

_cx_hosts() {
  local d="${CX_SSHD_DIR:-$HOME/.config/cx/ssh.d}" f
  [ -d "$d" ] || return 0
  for f in "$d"/*.conf; do
    [ -e "$f" ] || continue
    f=${f##*/}
    printf '%s\n' "${f%.conf}"
  done
}

# Hosts in the user's own ~/.ssh/config, for `cx host import`. Wildcard
# patterns are not hosts anyone can import.
_cx_ssh_hosts() {
  local cfg="${CX_SSH_CONFIG:-$HOME/.ssh/config}"
  [ -r "$cfg" ] || return 0
  awk 'tolower($1) == "host" { for (i = 2; i <= NF; i++) if ($i !~ /[*?!]/) print $i }' "$cfg" 2>/dev/null
}

_cx_goals() {
  local f
  f="$(_cx_cache_dir)/goals"
  [ -r "$f" ] || return 0
  cut -f2 "$f" 2>/dev/null | sort -u
}

# _cx_items KIND — "target<TAB>state" rows for a target kind.
_cx_items() {
  local t s
  t=$(_cx_targets_file)
  s="$(_cx_cache_dir)/state"
  [ -r "$t" ] || t=/dev/null
  [ -r "$s" ] || s=/dev/null
  case "$1" in
    all | hostproj | projslash | projects | units)
      cat "$t" 2>/dev/null
      cat "$s" 2>/dev/null
      ;;
    live) awk -F'\t' '$2 != "dead"' "$s" 2>/dev/null ;;
    known) cat "$s" 2>/dev/null ;;
  esac
}

# The tree walk, shared in spirit with cx.zsh: keep the two in step.
#
# A target is a small tree — host:project, then /worktree or @label under it,
# then @label under a worktree. Offering every leaf at once buries the
# projects, so a node is offered only once its parent has been typed in full:
# `cx open <TAB>` lists projects, `cx open web1:api<TAB>` adds its worktrees
# and sessions. A node with children gets no trailing space so a second TAB
# can descend; a parent that is only there to reach its children (a live
# session's project, which is not itself running) is never offered as final.
#
# Output: kind<TAB>candidate(+space when final)<TAB>state
#
# starts() rather than index(s, p) == 1: what index returns for an empty p
# differs between awks, and busybox says 0 — so an empty word matched nothing.
_cx_tree_awk='
function starts(s, p) { return substr(s, 1, length(p)) == p }
function parent(x,   p) {
  if (x ~ /@/) { p = x; sub(/@.*$/, "", p); return p }
  if (x ~ /\//) { p = x; sub(/\/[^\/]*$/, "", p); return p }
  return ""
}
function add(x, st, real,   p) {
  if (real) { isreal[x] = 1; if (st != "") state[x] = st }
  if (!(x in seen)) { seen[x] = 1; order[++n] = x }
  p = parent(x)
  if (p != "") { kids[p] = 1; add(p, "", 0) }
}
{
  t = $1
  if (depth == 0) sub(/[\/@].*$/, "", t)
  else if (depth == 1) sub(/@.*$/, "", t)
  if (t == "") next
  st = (t == $1) ? $2 : ""
  add(t, st, 1)
  h = t; sub(/:.*$/, "", h); hasnode[h] = 1
  if (bare && t ~ /:/) { b = t; sub(/^[^:]*:/, "", b); add(b, st, 1) }
}
END {
  for (i = 1; i <= n; i++) {
    x = order[i]
    if (!starts(x, cur)) continue
    p = parent(x)
    if (p != "" && !starts(cur, p)) continue
    if (x !~ /:/ && !bare) continue
    kind = (p == "") ? "project" : ((x ~ /@/) ? "session" : "worktree")
    if (slash) { if (p == "") print kind "\t" x "/\t"; continue }
    sp = (isreal[x] && !(x in kids)) ? " " : ""
    print kind "\t" x sp "\t" state[x]
  }
  m = split(hosts, hs, " ")
  for (i = 1; i <= m; i++)
    if (starts(hs[i] ":", cur) && cur !~ /:/ && !(hs[i] in hasnode))
      print "host\t" hs[i] ":\t"
}'

# _cx_targets KIND CUR — candidate targets, one per line.
_cx_targets() {
  local kind="$1" cur="$2" depth=2 bare=0 slash=0 hosts=""
  case "$kind" in
    hostcolon)
      _cx_hosts | sed 's/$/:/'
      return 0
      ;;
    units) depth=1 ;;
    projects | hostproj) depth=0 ;;
    projslash)
      depth=0
      slash=1
      ;;
  esac
  case "$kind" in
    live | known | hostproj) ;;
    *) hosts=$(_cx_hosts | tr '\n' ' ') ;;
  esac
  case "$cur" in
    '' | *:*) ;;
    *) bare=1 ;;
  esac
  local items out
  items=$(_cx_items "$kind")
  # A stop or a nudge wants a running session, but a missing or empty state
  # cache is not "nothing is running" — it is "cx has not looked yet".
  if [ -z "$items" ] && { [ "$kind" = live ] || [ "$kind" = known ]; }; then
    _cx_targets all "$cur"
    return 0
  fi
  out=$(printf '%s\n' "$items" | awk -F'\t' -v cur="$cur" -v depth="$depth" \
    -v bare="$bare" -v slash="$slash" -v hosts="$hosts" "$_cx_tree_awk" | cut -f2)
  [ -n "$out" ] && printf '%s\n' "$out"
  if [ "$kind" = hostproj ]; then
    _cx_hosts | sed 's/$/ /'
  fi
  return 0
}

# _cx_values KIND CUR — completions for a flag's value or a plain argument.
_cx_values() {
  local kind="$1" cur="$2" w
  case "$kind" in
    host) _cx_hosts | sed 's/$/ /' ;;
    sshhost) _cx_ssh_hosts | sed 's/$/ /' ;;
    goal) _cx_goals | sed 's/$/ /' ;;
    shell) printf '%s \n' bash zsh fish ;;
    memberop) printf '%s \n' add rm ;;
    goalstate) printf '%s \n' active paused "done" ;;
    permmode) printf '%s \n' acceptEdits auto bypassPermissions manual dontAsk plan ;;
    model) printf '%s \n' opus sonnet haiku ;;
    effort) printf '%s \n' low medium high xhigh max ;;
    icons) printf '%s \n' unicode nerd ;;
    outfmt) printf '%s \n' text json stream-json ;;
    states)
      # A comma-separated list: complete its last element.
      local done_part="" st
      case "$cur" in *,*) done_part="${cur%,*}," ;; esac
      for st in blocked idle working fresh starting dead unknown; do
        printf '%s%s \n' "$done_part" "$st"
      done
      ;;
    file)
      compgen -f -- "$cur" | while IFS= read -r w; do
        if [ -d "$w" ]; then printf '%s/\n' "$w"; else printf '%s \n' "$w"; fi
      done
      ;;
    word | '') ;;
    *) _cx_targets "$kind" "$cur" ;;
  esac
}

# ---------------------------------------------------------------------------
# Word handling
# ---------------------------------------------------------------------------

# Of the characters a target uses, the ones this shell splits words on. Bash's
# default COMP_WORDBREAKS contains both ':' and '@', so `web1:api@re` reaches
# a completion function as five words, and whatever is returned replaces only
# the text after the last break.
_cx_breaks() {
  local c out=""
  for c in : @; do
    case "${COMP_WORDBREAKS-}" in *"$c"*) out="$out$c" ;; esac
  done
  printf '%s' "$out"
}

# _cx_reassemble — _cx_w / _cx_cw: COMP_WORDS with targets glued back together.
#
# What bash-completion's _get_comp_words_by_ref -n : does, without requiring
# it. Two words are joined only when nothing separated them on the line, which
# is what distinguishes `web1:api` from `web1 : api`. Without COMP_LINE (a
# caller driving _cx by hand), a break character is taken to join.
_cx_reassemble() {
  local brk line i=0 n=0 w sep prev
  brk=$(_cx_breaks)
  _cx_w=()
  _cx_cw=0
  line="${COMP_LINE-}"
  [ -n "$line" ] && line="${line:0:${COMP_POINT:-${#line}}}"
  while [ "$i" -le "$COMP_CWORD" ]; do
    w="${COMP_WORDS[i]-}"
    sep=0
    if [ -n "${COMP_LINE-}" ]; then
      prev="$line"
      line="${line#"${line%%[![:space:]]*}"}"
      [ "$prev" != "$line" ] && sep=1
      line="${line#"$w"}"
    fi
    if [ "$n" -gt 0 ] && [ "$sep" = 0 ] && [ -n "$brk" ] && _cx_joins "$brk" "${_cx_w[n - 1]}" "$w"; then
      _cx_w[n - 1]="${_cx_w[n - 1]}$w"
    else
      _cx_w[n]="$w"
      n=$((n + 1))
    fi
    i=$((i + 1))
  done
  _cx_cw=$((n - 1))
}

# _cx_joins BREAKS PREV WORD — does WORD continue PREV across a break?
_cx_joins() {
  case "$3" in
    '') ;;
    *[!"$1"]*) ;;
    *) return 0 ;; # the word is only break characters: `:` or `@`
  esac
  case "$2" in
    *["$1"]) return 0 ;;
  esac
  return 1
}

# _cx_reply CUR CANDIDATES — COMPREPLY from newline-separated candidates.
#
# Candidates carry their own trailing space when they are final. The function
# is registered with -o nospace because bash 3.2 has no compopt, and a target
# prefix — `web1:`, `web1:api/` — must not be followed by one.
#
# The candidates arrive as an argument, not on stdin: `... | _cx_reply` would
# run in a subshell and set a COMPREPLY nobody sees.
_cx_reply() {
  local cur="$1" brk pre="" c
  COMPREPLY=()
  [ -n "${2-}" ] || return 0
  brk=$(_cx_breaks)
  if [ -n "$brk" ]; then
    # Bash replaces only the text after the last break, so strip what is
    # before it — the job bash-completion's __ltrim_colon_completions does.
    case "$cur" in *["$brk"]*) pre="${cur%"${cur##*[$brk]}"}" ;; esac
  fi
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    case "$c" in
      "$cur"*) COMPREPLY[${#COMPREPLY[@]}]="${c#"$pre"}" ;;
    esac
  done <<EOF
$2
EOF
}

_cx_words_sp() {
  local w
  for w in "$@"; do printf '%s \n' "$w"; done
}

# _cx_flag_kind CMD SUB FLAG — the value KIND a flag takes, "switch", or
# nothing when the command does not know it.
_cx_flag_kind() {
  local f
  for f in $(_cx_flags "$1" "$2"); do
    case "$f" in
      "$3") printf switch && return 0 ;;
      "$3="*) printf '%s' "${f#*=}" && return 0 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

_cx() {
  local _cx_w _cx_cw
  _cx_reassemble
  local cur="${_cx_w[_cx_cw]-}"
  local i=1 w cmd="" sub="" npos=0 want="" subs="" kind

  # Walk what is before the cursor. Global flags are skipped wherever they
  # are, so `cx --json ls <TAB>` knows the command is ls; a flag that takes a
  # value swallows the next word, so `cx goal --host web1 <TAB>` knows web1 is
  # not the subverb.
  while [ "$i" -lt "$_cx_cw" ]; do
    w="${_cx_w[i]}"
    i=$((i + 1))
    if [ -n "$want" ]; then
      want=""
      continue
    fi
    case " $_cx_global_flags " in *" $w "*) continue ;; esac
    case "$w" in
      --)
        # Everything after -- is Claude Code's, not cx's.
        [ -n "$cmd" ] && return 0
        ;;
      -*)
        [ -n "$cmd" ] || continue
        kind=$(_cx_flag_kind "$cmd" "$sub" "$w")
        [ -n "$kind" ] && [ "$kind" != switch ] && want="$kind"
        ;;
      *)
        if [ -z "$cmd" ]; then
          cmd=$(_cx_norm_cmd "$w")
          subs=$(_cx_subverbs "$cmd")
        elif [ -n "$subs" ] && [ -z "$sub" ]; then
          sub=$(_cx_norm_sub "$w" "$cmd")
        else
          npos=$((npos + 1))
        fi
        ;;
    esac
  done

  # Word lists below are split on purpose.
  # shellcheck disable=SC2086
  if [ -n "$want" ]; then
    _cx_reply "$cur" "$(_cx_values "$want" "$cur")"
  elif [ -z "$cmd" ]; then
    case "$cur" in
      -*) _cx_reply "$cur" "$(_cx_words_sp $_cx_global_flags -h --help -V --version)" ;;
      *) _cx_reply "$cur" "$(_cx_words_sp $_cx_commands)" ;;
    esac
  elif [ "${cur#-}" != "$cur" ]; then
    _cx_reply "$cur" "$(
      printf '%s\n' "$(_cx_flags "$cmd" "$sub")" | tr ' ' '\n' | sed -n 's/=.*//; /./s/$/ /p'
      _cx_words_sp $_cx_global_flags --help
    )"
  elif [ -n "$subs" ] && [ -z "$sub" ]; then
    _cx_reply "$cur" "$(_cx_words_sp $subs)"
  else
    kind=$(_cx_positional "$cmd" "$sub" $((npos + 1)))
    _cx_reply "$cur" "$(_cx_values "$kind" "$cur")"
  fi
  return 0
}

complete -o nospace -F _cx cx
