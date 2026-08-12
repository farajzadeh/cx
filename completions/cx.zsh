#compdef cx
# zsh completion for cx
#
# Targets come from ~/.cache/cx/targets, refreshed by any cx listing. No
# network work happens here: tab completion must never block on SSH.

_cx_targets() {
  local f="${CX_CACHE_DIR:-$HOME/.cache/cx}/targets"
  [[ -r $f ]] && cat "$f"
}

_cx_hosts() {
  local d="${CX_SSHD_DIR:-$HOME/.config/cx/ssh.d}"
  [[ -d $d ]] || return
  local f
  for f in "$d"/*.conf(N); do
    print -r -- "${${f:t}%.conf}"
  done
}

_cx() {
  local -a cmds
  cmds=(
    'host:manage servers'
    'provision:install or update the agent'
    'login:one-time Claude Code sign-in'
    'doctor:check requirements and connectivity'
    'new:create a project'
    'ls:list projects and worktrees'
    'rm:remove a project'
    'wt:git worktrees for parallel tasks'
    'worktree:git worktrees for parallel tasks'
    'open:attach a Claude session'
    'resume:attach and pick a past conversation'
    'shell:plain shell, no Claude'
    'code:open in VS Code over Remote-SSH'
    'ask:one-shot question'
    'status:live sessions'
    'stop:end a session'
    'cache:inspect or drop cached data'
  )

  if (( CURRENT == 2 )); then
    _describe 'command' cmds
    return
  fi

  case ${words[2]} in
    host)
      if (( CURRENT == 3 )); then
        _values 'subcommand' add import ls test edit rm
      else
        compadd -- ${(f)"$(_cx_hosts)"}
      fi
      ;;
    provision|login|doctor|cache)
      compadd -- ${(f)"$(_cx_hosts)"} --all
      ;;
    new)
      compadd -S '' -- ${(f)"$(_cx_hosts)"//(#e)/:}
      ;;
    ls)
      compadd -- ${(f)"$(_cx_hosts)"} --git --json
      ;;
    wt|worktree)
      if (( CURRENT == 3 )); then
        _values 'subcommand' add ls rm
      else
        compadd -- ${(f)"$(_cx_targets)"} --branch --from --force
      fi
      ;;
    open|resume|ask)
      compadd -- ${(f)"$(_cx_targets)"} --dangerously-skip-permissions
      ;;
    stop)
      compadd -- ${(f)"$(_cx_targets)"} --all
      ;;
    shell|code|rm)
      compadd -- ${(f)"$(_cx_targets)"}
      ;;
  esac
}

_cx "$@"
