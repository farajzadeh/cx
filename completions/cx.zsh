#compdef cx
# zsh completion for cx
#
# Works three ways:
#   - autoloaded as _cx from a directory on $fpath (it is the file's name in
#     completions/omz/cx/, which is how the oh-my-zsh plugin ships it);
#   - sourced, after compinit:     source ~/.local/share/cx/completions/cx.zsh
#   - generated:                   source <(cx completion zsh)
#
# NO NETWORK WORK, EVER. Everything comes from files cx keeps as a side effect
# of commands the user ran anyway — ~/.cache/cx/targets (projects and
# worktrees), ~/.cache/cx/state (sessions and what they are doing),
# ~/.cache/cx/goals, and ~/.config/cx/ssh.d/*.conf. A tab that hangs on an
# unreachable server is worse than any stale list.
#
# TO ADD A COMMAND OR A FLAG: _cx_cmd_desc (commands), _cx_sub_desc
# (subverbs) and _cx_specs (flags and arguments, one _arguments spec per
# line). completions/cx.bash has the same tables; keep the two in step.

# ---------------------------------------------------------------------------
# Tables
# ---------------------------------------------------------------------------

typeset -ga _cx_cmd_desc _cx_globals
_cx_cmd_desc=(
  'host:manage servers'
  'provision:install or update the agent on a server'
  'login:one-time Claude Code sign-in on a server'
  'doctor:check requirements and connectivity'
  'new:create and register a project'
  'ls:list projects and worktrees'
  'rm:unregister a project'
  'wt:git worktrees for parallel tasks'
  'worktree:git worktrees for parallel tasks'
  'open:attach a Claude session'
  'resume:attach and pick a past conversation'
  'shell:plain shell in the project, no Claude'
  'code:open in VS Code over Remote-SSH'
  'ask:one-shot question, printed here'
  'status:live sessions across servers'
  'stop:end a session'
  'forget:drop a finished session from the lists'
  'peek:what each session is doing now'
  'nudge:type a prompt into a running session'
  'bar:one line for a tmux status bar'
  'tabs:a tmux tab per live session, here'
  'jump:go to the tab of the session that needs you'
  'goal:definitions of done for your sessions'
  'driver:print the cx-driver subagent'
  'cache:inspect or drop cached data'
  'completion:print the shell completion script'
  'find:pick a target interactively'
  'pick:pick a target interactively'
  'help:show usage'
  'version:print the version'
)

# Valid anywhere: bin/cx strips them before choosing a subcommand.
_cx_globals=(
  '(-r --refresh)'{-r,--refresh}'[force a fetch, ignoring the cache]'
  '--no-cache[bypass the cache without updating it]'
  '--stale[accept cached data of any age]'
  '--json[machine-readable output]'
  '(-y --yes)'{-y,--yes}'[assume yes to prompts]'
  '--no-color[disable color]'
)

# _cx_sub_desc CMD — the subverbs of CMD, as name:description, in reply.
_cx_sub_desc() {
  case $1 in
    host) reply=(
      'add:add a server'
      'import:adopt a host from ~/.ssh/config'
      'ls:list servers'
      'test:check connectivity and agent status'
      'edit:edit the definition in $EDITOR'
      'rm:remove a server (the server itself is untouched)') ;;
    wt) reply=(
      'add:a worktree - own branch, own directory'
      'ls:list worktrees'
      'rm:remove one (its branch is kept)') ;;
    goal) reply=(
      'new:a definition of done, and who is on it'
      'ls:list goals'
      'show:one goal in full'
      'dod:change the definition of done'
      'member:add or remove a session'
      'pause:stop the driver, not the work'
      'resume:let the driver pick it up again'
      'done:mark it finished'
      'log:record what happened'
      'on-stop:drive itself when a member finishes a turn'
      'rm:remove a goal') ;;
    cache) reply=(
      'status:what is cached, and how old'
      'clear:drop cached data'
      'refresh:re-fetch one server') ;;
    *) reply=() ;;
  esac
}

# _cx_specs CMD [SUB] — _arguments specs for CMD, in reply. One per line.
_cx_specs() {
  local -a claude
  claude=(
    '--permission-mode[how much Claude asks before acting]:mode:((acceptEdits\:"apply edits, ask before commands" plan\:"plan only, change nothing" auto manual dontAsk bypassPermissions\:"ask for nothing at all"))'
    '--dangerously-skip-permissions[bypass ALL permission checks]'
    '--model[model]:model:(opus sonnet haiku)'
    '--effort[reasoning effort]:level:(low medium high xhigh max)'
  )
  # What `new` and `wt add` take to open the thing they have just made.
  local -a open_after
  open_after=(
    '(--no-open)--open[open it once created]'
    '(--open)--no-open[do not open it, and do not ask]'
    '(-d --detach)'{-d,--detach}'[open it, but do not attach]'
    '--label[open it as a named session]:label: '
    '--no-hooks[without the hooks that report its state]'
    $claude
  )
  reply=()
  case "$1${2:+ $2}" in
    'host add') reply=(
      '--alias[short name you will type]:alias: '
      '--hostname[address or DNS name]:hostname:_hosts'
      '--user[login user]:user:_users'
      '--port[SSH port]:port: '
      '--identity[private key file]:key file:_files'
      '--root[project root on the server]:path: '
      '--no-test[skip the connection check]') ;;
    'host import') reply=('--root[project root on the server]:path: ' '1:ssh alias:_cx_ssh_hosts') ;;
    'host test' | 'host edit' | 'host rm') reply=('1:server:_cx_hosts') ;;
    provision) reply=('(-a --all *)'{-a,--all}'[every server]' '*:server:_cx_hosts') ;;
    login | doctor) reply=('1:server:_cx_hosts') ;;
    ls) reply=(
      '--git[show git branch and state]'
      '(-f --filter)'{-f,--filter}'[only what matches]:pattern: '
      '*--host[only this server]:server:_cx_hosts'
      '--live[only projects with a live session]'
      '--active[touched within]:duration (30m, 2h, 7d): '
      '--idle[not touched within]:duration (30m, 2h, 7d): '
      '--dirty[only uncommitted changes (implies --git)]'
      '--no-worktrees[projects only]'
      '--group[layout]:group:(host none)'
      '--sort[order]:key:(name active sessions host none)'
      '1:server:_cx_hosts') ;;
    'host ls') reply=(
      '(-f --filter)'{-f,--filter}'[only what matches]:pattern: '
      '(--down)--reachable[only servers last seen up]'
      '(--reachable)--down[only servers last seen down]') ;;
    new) reply=(
      '--repo[clone this repository]:url: '
      '--root[project root on the server]:directory: '
      $open_after
      '1:host\:name:_cx_target hostcolon') ;;
    rm) reply=('--purge[also delete the files]' '1:project:_cx_target projects') ;;
    'wt add') reply=(
      '--branch[branch name]:branch: '
      '--from[what to branch from]:ref: '
      $open_after
      '1:project/worktree:_cx_target projslash') ;;
    'wt ls') reply=(
      '(-f --filter)'{-f,--filter}'[only what matches]:pattern: '
      '1:server or project:_cx_target hostproj') ;;
    'wt rm') reply=(
      '--force[discard uncommitted changes]'
      '--merged[every worktree that is merged]'
      '1:worktree:_cx_target units') ;;
    open | resume) reply=(
      $claude
      '(-d --detach)'{-d,--detach}'[start it, do not attach]'
      '--no-hooks[without the hooks that report its state]'
      '1:target:_cx_target all') ;;
    shell) reply=(
      '(-d --detach)'{-d,--detach}'[start it, do not attach]'
      '--no-hooks[without the hooks that report its state]'
      '1:target:_cx_target all') ;;
    code) reply=('1:project or worktree:_cx_target units') ;;
    ask) reply=(
      $claude
      '--output-format[output format]:format:(text json stream-json)'
      '--json-schema[JSON Schema for structured output]:schema: '
      '--max-budget-usd[cap what this one call may spend]:amount: '
      '1:target:_cx_target all'
      '*:prompt: ') ;;
    stop) reply=('--all[every session of the project]' '1:session:_cx_target live') ;;
    forget) reply=('1:session:_cx_target known') ;;
    peek) reply=(
      '--all[list finished sessions too]'
      '--tail[include the last N messages in --json]:N: '
      '--goal[just that goal'"'"'s members]:goal:_cx_goals'
      '1:target:_cx_target all') ;;
    nudge) reply=('--force[send it even if the session is busy]' '1:session:_cx_target live' '*:prompt: ') ;;
    bar) reply=(
      '--setup[print tmux configuration and exit]'
      '--plain[no tmux styling]'
      '--attached[include sessions you already have open]'
      '--color[colour the states]'
      '--icons[icon set]:set:(unicode nerd)'
      '--window[one tab'"'"'s state icon]:target:_cx_target all'
      '--max[how many to name before +N]:N: '
      '--states[which states count as waiting]:states:_cx_states'
      '--label[the prefix]:text: ') ;;
    tabs) reply=(
      '(-n --dry-run)'{-n,--dry-run}'[show what it would open]'
      '--no-attach[build it, do not attach]'
      '--take[open sessions held elsewhere too]'
      '(-s --session)'{-s,--session}'[tmux session name]:name: ') ;;
    jump) reply=('--states[which states to go to, in order]:states:_cx_states') ;;
    # Not the hidden --preview, which is the picker talking to itself.
    find | pick) reply=('(-p --print)'{-p,--print}'[print the target instead of opening it]' '*:query:_cx_target all') ;;
    completion) reply=('1:shell:(bash zsh fish)') ;;
    goal | 'goal '*)
      reply=('--host[the server holding the goal]:server:_cx_hosts')
      case $2 in
        new) reply+=('*--member[a session working on it]:target:_cx_target all' '1:name: ' '2:definition of done: ') ;;
        ls) reply+=('--state[only goals in this state]:state:(active paused done)') ;;
        show | pause | resume | done | rm) reply+=('1:goal:_cx_goals') ;;
        dod) reply+=('1:goal:_cx_goals' '2:definition of done: ') ;;
        member) reply+=('1:operation:((add\:"add a member" rm\:"remove a member"))' '2:goal:_cx_goals' '3:target:_cx_target all') ;;
        log) reply+=('--event[event kind]:event: ' '--target[the session it concerns]:target:_cx_target all' '1:goal:_cx_goals' '2:what happened: ') ;;
        on-stop) reply+=('--max[runs an hour at most]:N: ' '--model[model]:model:(opus sonnet haiku)' '--off[stop driving itself]' '1:goal:_cx_goals') ;;
      esac
      ;;
    'cache clear' | 'cache refresh') reply=('1:server:_cx_hosts') ;;
  esac
}

# Spellings the commands accept, folded to the ones the tables use.
_cx_norm_sub() {
  case $2 in
    new) [[ $1 == wt ]] && REPLY=add || REPLY=new ;;
    list) REPLY=ls ;;
    remove | delete) REPLY=rm ;;
    check) REPLY=test ;;
    clean | purge) REPLY=clear ;;
    *) REPLY=$2 ;;
  esac
}

# ---------------------------------------------------------------------------
# Local sources — files only
# ---------------------------------------------------------------------------

_cx_cache_dir() { print -r -- "${CX_CACHE_DIR:-$HOME/.cache/cx}"; }

_cx_host_names() {
  local d="${CX_SSHD_DIR:-$HOME/.config/cx/ssh.d}" f
  [[ -d $d ]] || return 0
  for f in "$d"/*.conf(N); do
    print -r -- "${${f:t}%.conf}"
  done
}

_cx_hosts() {
  local -a hs
  hs=(${(f)"$(_cx_host_names)"}) hs=(${^hs:#}:server)
  _describe -t hosts 'server' hs
}

_cx_ssh_hosts() {
  local cfg="${CX_SSH_CONFIG:-$HOME/.ssh/config}"
  local -a hs
  [[ -r $cfg ]] || return 1
  hs=(${(f)"$(awk 'tolower($1) == "host" { for (i = 2; i <= NF; i++) if ($i !~ /[*?!]/) print $i }' "$cfg" 2>/dev/null)"})
  _describe -t hosts 'ssh host' hs
}

_cx_goals() {
  local f="$(_cx_cache_dir)/goals" h n st
  local -a gs
  local -A seen
  [[ -r $f ]] || return 1
  while IFS=$'\t' read -r h n st; do
    [[ -n $n && -z ${seen[$n]} ]] || continue
    seen[$n]=1
    gs+=("${n//:/\\:}:${st:-goal} on $h")
  done <"$f"
  _describe -t goals 'goal' gs
}

_cx_states() {
  _values -s , 'state' \
    'blocked[mid-turn and gone quiet, usually a permission prompt]' \
    'idle[the last turn finished, waiting for you]' \
    'working[busy right now]' \
    'fresh[up, nothing asked of it yet]' \
    'starting[Claude has not finished starting]' \
    'dead[Claude exited]' \
    'unknown[nothing readable]'
}

# _cx_items KIND — "target<TAB>state" rows for a target kind.
_cx_items() {
  local d="$(_cx_cache_dir)"
  local t="$d/targets" s="$d/state"
  [[ -r $t ]] || t=/dev/null
  [[ -r $s ]] || s=/dev/null
  case $1 in
    live) awk -F'\t' '$2 != "dead"' "$s" 2>/dev/null ;;
    known) cat "$s" 2>/dev/null ;;
    *) cat "$t" "$s" 2>/dev/null ;;
  esac
}

# The same tree walk as completions/cx.bash — keep the two in step. A node is
# offered once its parent is typed in full, so projects come first and a
# project's worktrees and sessions once it is. Output:
#   kind<TAB>candidate(+space when final)<TAB>state
typeset -g _cx_tree_awk='
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
}'

# _cx_target KIND — targets, grouped as servers / projects / worktrees /
# sessions, each described by what it is doing when the state cache knows.
_cx_target() {
  local kind=all cur=$PREFIX depth=2 bare=0 slash=0 a
  # Called as an _arguments action, which adds its own compadd options
  # (-J, -X ...) to the ones in the spec — so find the kind, not $1.
  for a in "$@"; do
    case $a in
      all | units | projects | live | known | hostcolon | projslash | hostproj) kind=$a ;;
    esac
  done
  case $kind in
    units) depth=1 ;;
    projects | hostproj) depth=0 ;;
    projslash) depth=0 slash=1 ;;
  esac
  [[ -n $cur && $cur != *:* ]] && bare=1

  local -a hs
  hs=(${(f)"$(_cx_host_names)"}) hs=(${^hs:#}:server)
  if [[ $kind == hostcolon ]]; then
    _describe -t hosts 'server' hs -S ':'
    return
  fi

  local items
  local -a rows
  items=$(_cx_items $kind)
  # No state cache is "not looked yet", not "nothing running".
  if [[ -z $items && $kind == (live|known) ]]; then
    _cx_target all
    return
  fi
  rows=(${(f)"$(print -r -- "$items" | awk -F'\t' -v cur="$cur" -v depth=$depth \
    -v bare=$bare -v slash=$slash "$_cx_tree_awk")"})

  local -a p_fin p_stem w_fin w_stem s_fin s_stem
  local r k c st e
  for r in $rows; do
    k=${r%%$'\t'*}
    r=${r#*$'\t'}
    c=${r%%$'\t'*}
    st=${r#*$'\t'}
    e="${${c% }//:/\\:}:${st:-$k}"
    if [[ $c == *' ' ]]; then
      case $k in
        project) p_fin+=("$e") ;;
        worktree) w_fin+=("$e") ;;
        session) s_fin+=("$e") ;;
      esac
    else
      case $k in
        project) p_stem+=("$e") ;;
        worktree) w_stem+=("$e") ;;
        session) s_stem+=("$e") ;;
      esac
    fi
  done

  local ret=1
  _tags hosts projects worktrees sessions
  while _tags; do
    if [[ $cur != *:* && $kind != (live|known) ]]; then
      if [[ $kind == hostproj ]]; then
        _requested hosts && _describe -t hosts 'server' hs && ret=0
      else
        _requested hosts && _describe -t hosts 'server' hs -S ':' && ret=0
      fi
    fi
    _requested projects && _describe -t projects 'project' p_fin -- p_stem -S '' && ret=0
    _requested worktrees && _describe -t worktrees 'worktree' w_fin -- w_stem -S '' && ret=0
    _requested sessions && _describe -t sessions 'session' s_fin -- s_stem -S '' && ret=0
    (( ret )) || break
  done
  return ret
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

_cx() {
  local curcontext=$curcontext state state_descr line cmd sub ret=1
  local -a reply
  typeset -A opt_args

  _arguments -C -s : $_cx_globals \
    '(- *)'{-h,--help}'[show usage]' \
    '(- *)'{-V,--version}'[print the version]' \
    '1:command:->command' \
    '*:: :->args' && return 0

  case $state in
    command)
      _describe -t commands 'cx command' _cx_cmd_desc
      return
      ;;
    args) ;;
    *) return 1 ;;
  esac

  cmd=$words[1]
  [[ $cmd == worktree ]] && cmd=wt
  curcontext=${curcontext%:*:*}:cx-$cmd:

  _cx_sub_desc $cmd
  if (( ! $#reply )); then
    _cx_specs $cmd
    _arguments -s -S : $_cx_globals '(- *)'{-h,--help}'[show help]' $reply
    return
  fi

  # A command with subverbs: its own flags (goal --host) may come first.
  local -a subs
  subs=($reply)
  _cx_specs $cmd
  state=
  _arguments -C -s : $_cx_globals '(- *)'{-h,--help}'[show help]' $reply \
    '1:subcommand:->sub' \
    '*:: :->subargs' && return 0
  case $state in
    sub)
      _describe -t subcommands "cx $cmd subcommand" subs
      return
      ;;
    subargs) ;;
    *) return 1 ;;
  esac

  _cx_norm_sub $cmd $words[1]
  sub=$REPLY
  curcontext=${curcontext%:*:*}:cx-$cmd-$sub:
  _cx_specs $cmd $sub
  _arguments -s -S : $_cx_globals '(- *)'{-h,--help}'[show help]' $reply
}

# Autoloaded from $fpath, this file is _cx's body: run it. Sourced (or eval'd
# from `cx completion zsh`), register it — with compinit first if the user's
# setup has not run it, since compdef does not exist until it has.
if [[ ${zsh_eval_context[-1]} == loadautofunc ]]; then
  _cx "$@"
else
  (( $+functions[compdef] )) || { autoload -Uz compinit && compinit -i; }
  compdef _cx cx
fi
