# bash completion for cx
#
# Reads ~/.cache/cx/targets, which cx refreshes as a side effect of any
# listing. Completion performs NO network work — not even a background
# refresh. Tab must never hang on an unreachable server, and a slightly stale
# target list is a far better failure than a frozen shell.

_cx_targets_file() {
  printf '%s' "${CX_CACHE_DIR:-$HOME/.cache/cx}/targets"
}

_cx_hosts() {
  local d="${CX_SSHD_DIR:-$HOME/.config/cx/ssh.d}" f
  [ -d "$d" ] || return 0
  for f in "$d"/*.conf; do
    [ -e "$f" ] || continue
    basename "$f" .conf
  done
}

_cx() {
  local cur prev cmds
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD - 1]}"

  cmds="host provision login doctor new ls rm wt worktree open resume shell code ask status stop cache help version"

  if [ "$COMP_CWORD" -eq 1 ]; then
    # shellcheck disable=SC2207
    COMPREPLY=($(compgen -W "$cmds" -- "$cur"))
    return
  fi

  case "${COMP_WORDS[1]}" in
    host)
      if [ "$COMP_CWORD" -eq 2 ]; then
        # shellcheck disable=SC2207
        COMPREPLY=($(compgen -W "add import ls test edit rm" -- "$cur"))
      else
        # shellcheck disable=SC2207
        COMPREPLY=($(compgen -W "$(_cx_hosts)" -- "$cur"))
      fi
      ;;
    provision | login | doctor)
      # shellcheck disable=SC2207
      COMPREPLY=($(compgen -W "$(_cx_hosts) --all" -- "$cur"))
      ;;
    cache)
      if [ "$COMP_CWORD" -eq 2 ]; then
        # shellcheck disable=SC2207
        COMPREPLY=($(compgen -W "status clear refresh" -- "$cur"))
      else
        # shellcheck disable=SC2207
        COMPREPLY=($(compgen -W "$(_cx_hosts)" -- "$cur"))
      fi
      ;;
    new)
      case "$prev" in
        --repo | --root) return ;;
      esac
      # shellcheck disable=SC2207
      COMPREPLY=($(compgen -W "$(_cx_hosts | sed 's/$/:/') --repo --root" -- "$cur"))
      ;;
    ls)
      # shellcheck disable=SC2207
      COMPREPLY=($(compgen -W "$(_cx_hosts) --git --json" -- "$cur"))
      ;;
    wt | worktree)
      if [ "$COMP_CWORD" -eq 2 ]; then
        # shellcheck disable=SC2207
        COMPREPLY=($(compgen -W "add ls rm" -- "$cur"))
        return
      fi
      case "$prev" in
        --branch | --from) return ;;
      esac
      local wf
      wf=$(_cx_targets_file)
      # `wt add` names a worktree that does not exist yet, so completing the
      # project it hangs off is the most that can be offered.
      if [ -r "$wf" ]; then
        # shellcheck disable=SC2207
        COMPREPLY=($(compgen -W "$(cat "$wf") --branch --from --force" -- "$cur"))
      else
        # shellcheck disable=SC2207
        COMPREPLY=($(compgen -W "$(_cx_hosts | sed 's/$/:/')" -- "$cur"))
      fi
      ;;
    open | resume | shell | code | ask | stop | rm)
      local f
      f=$(_cx_targets_file)
      if [ -r "$f" ]; then
        # shellcheck disable=SC2207
        COMPREPLY=($(compgen -W "$(cat "$f")" -- "$cur"))
      else
        # shellcheck disable=SC2207
        COMPREPLY=($(compgen -W "$(_cx_hosts | sed 's/$/:/')" -- "$cur"))
      fi
      ;;
  esac
}

complete -F _cx cx
